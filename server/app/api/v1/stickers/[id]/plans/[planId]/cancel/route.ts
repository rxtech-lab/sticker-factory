import { z } from "zod";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { cancelPlan } from "@/lib/services/plans";

type Context = { params: Promise<{ id: string; planId: string }> };

const CancelPlanRequestSchema = z.object({
  reason: z.string().trim().min(1).max(1_000).optional(),
}).strict();

/**
 * Dismisses a finalized plan without generating anything.
 *
 * An optional `reason` is stored on the plan and fed back into the next planning turn, so the agent
 * knows what the user turned down instead of proposing the same thing again. The body is optional
 * because a plain dismissal is the common case and older clients send none at all.
 */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, planId } = await context.params;
    const key = requireIdempotencyKey(request);
    const hasBody = Number(request.headers.get("content-length") ?? 0) > 0;
    const { reason } = hasBody
      ? await readJson(request, (value) => CancelPlanRequestSchema.parse(value))
      : { reason: undefined };
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `cancel-plan:${id}:${planId}`,
      key,
      request: { planId, reason },
    }, async () => ({
      status: 200,
      body: await cancelPlan(db, principal.sub, id, planId, reason),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
