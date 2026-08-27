import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { removePackItem } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string; stickerId: string }> };

export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId, stickerId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `remove-pack-item:${packId}:${stickerId}`,
      key,
      request: { packId, stickerId },
    }, async () => ({ status: 200, body: await removePackItem(db, principal.sub, packId, stickerId) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
