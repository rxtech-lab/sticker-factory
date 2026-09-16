import { clientDocumentVersion } from "@/lib/contracts/sticker";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { confirmPlan } from "@/lib/services/plans";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { startGenerationWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string; planId: string }> };

/**
 * Starts generating a finalized plan.
 *
 * The plan is already persisted, so there is no body — confirming is a bare "go" signal. The
 * response envelope matches the chat-message endpoint so the client reuses the same job
 * observation path.
 */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, planId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `confirm-plan:${id}:${planId}`,
      key,
      request: { planId },
    }, async () => {
      const turn = await confirmPlan(db, principal.sub, id, planId, clientDocumentVersion(request));
      let workflowRunId: string | null = null;
      let state: "queued" | "failed" = "queued";
      try {
        workflowRunId = await startGenerationWorkflow(db, turn.jobId);
      } catch {
        state = "failed";
      }
      return { status: 202, body: {
        message: { id: turn.messageId, status: state === "failed" ? "failed" : "streaming" },
        job: { id: turn.jobId, state, workflowRunId, retryable: state === "failed", eventsUrl: `/api/v1/jobs/${turn.jobId}/events` },
      } };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
