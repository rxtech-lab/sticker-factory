import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { retryFailedChatTurn } from "@/lib/services/stickers";
import { startGenerationWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string; messageId: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, messageId } = await context.params;
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `retry-message:${id}:${messageId}`,
      key: requireIdempotencyKey(request),
      request: { id, messageId },
    }, async () => {
      const turn = await retryFailedChatTurn(db, principal.sub, id, messageId);
      const workflowRunId = await startGenerationWorkflow(db, turn.jobId);
      return { status: 202, body: { messageId, job: { id: turn.jobId, state: "queued", workflowRunId, eventsUrl: `/api/v1/jobs/${turn.jobId}/events` } } };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
