import { z } from "zod";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { selectPlanVersion } from "@/lib/services/plans";

type Context = { params: Promise<{ id: string; planId: string }> };
const RequestSchema = z.object({
  currentPlanId: z.string().uuid(),
  currentRevision: z.number().int().positive(),
}).strict();

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, planId } = await context.params;
    const key = requireIdempotencyKey(request);
    const body = await readJson(request, RequestSchema.parse);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub, operation: `select-plan:${id}:${planId}`, key,
      request: { planId, ...body },
    }, async () => ({
      status: 200,
      body: await selectPlanVersion(db, principal.sub, id, planId, body.currentPlanId, body.currentRevision),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
