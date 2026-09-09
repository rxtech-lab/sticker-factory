import { z } from "zod";
import { PlanEditV1Schema } from "@/lib/contracts/plan";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { editPlan } from "@/lib/services/plans";

type Context = { params: Promise<{ id: string; planId: string }> };
const RequestSchema = z.object({
  /** The revision the editor was opened on, so a plan the agent rewrote underneath is refused. */
  currentRevision: z.number().int().positive(),
  edit: PlanEditV1Schema,
}).strict();

/** Saves the user's own edit of the live plan card as a new version. */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id, planId } = await context.params;
    const key = requireIdempotencyKey(request);
    const body = await readJson(request, RequestSchema.parse);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub, operation: `edit-plan:${id}:${planId}`, key,
      request: { planId, ...body },
    }, async () => ({
      status: 200,
      body: await editPlan(db, principal.sub, id, planId, body.edit, body.currentRevision),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
