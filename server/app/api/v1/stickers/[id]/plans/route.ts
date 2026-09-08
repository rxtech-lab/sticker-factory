import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPlans, serializePlan } from "@/lib/services/plans";
import { assertOwnedSticker } from "@/lib/services/sticker-summaries";

type Context = { params: Promise<{ id: string }> };

/** Saved plan versions, oldest first, independent of transcript pagination. */
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    await assertOwnedSticker(db, principal.sub, id);
    const rows = await listPlans(db, principal.sub, id);
    return noStoreJson({ data: rows.reverse().map((row) => serializePlan(row)) });
  });
}
