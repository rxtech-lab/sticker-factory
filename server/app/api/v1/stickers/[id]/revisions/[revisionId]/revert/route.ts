import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, idempotencyUuid, requireIdempotencyKey } from "@/lib/services/idempotency";
import { runRevisionDecisionWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string; revisionId: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, revisionId } = await context.params;
    const operation = `revert:${id}`;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation, key, request: { revisionId } }, async () => ({
      status: 201,
      body: await runRevisionDecisionWorkflow({ ownerId: principal.sub, stickerId: id, revisionId, decision: "revert", decisionId: idempotencyUuid(principal.sub, operation, key) }),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
