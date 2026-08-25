import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { cancelGenerationWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ jobId: string }> };

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { jobId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `cancel-generation:${jobId}`,
      key,
      request: { jobId },
    }, async () => ({
      status: 200,
      body: await cancelGenerationWorkflow(db, principal.sub, jobId),
    }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
