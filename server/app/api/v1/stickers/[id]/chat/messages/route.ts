import { isAppClipClient } from "@/lib/subscription/app-clip";
import { PostChatMessageRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createChatTurn, listChatMessages } from "@/lib/services/stickers";
import { startGenerationWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const url = new URL(request.url);
    const afterSequence = integerQuery(url.searchParams.get("afterSequence"), { name: "afterSequence", min: 0, max: Number.MAX_SAFE_INTEGER });
    const beforeSequence = integerQuery(url.searchParams.get("beforeSequence"), { name: "beforeSequence", min: 1, max: Number.MAX_SAFE_INTEGER });
    if (afterSequence !== undefined && beforeSequence !== undefined) {
      throw new (await import("@/lib/http/errors")).ApiError(400, "INVALID_QUERY", "Use afterSequence or beforeSequence, not both");
    }
    return noStoreJson(await listChatMessages(db, principal.sub, id, {
      afterSequence,
      beforeSequence,
      limit: integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 200, defaultValue: 100 }),
    }));
  });
}

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const body = await readJson(request, PostChatMessageRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `chat-message:${id}`,
      key,
      request: body,
    }, async () => {
      const turn = await createChatTurn(db, principal.sub, id, body, isAppClipClient(principal));
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
