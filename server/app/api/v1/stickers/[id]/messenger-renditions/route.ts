import { MessengerRenditionsRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { bindMessengerRenditions } from "@/lib/services/stickers";

type Context = { params: Promise<{ id: string }> };

/**
 * Attach the WhatsApp and Telegram renditions the phone encoded when this sticker was added to a
 * pack.
 *
 * Modelled on the pack-item routes rather than on `../exports`: there is no server-side render to
 * run and no credit to hold, so this answers 200 with the updated sticker instead of 202 with a job
 * to watch. The client needs that summary — it has just made the sticker sendable and would
 * otherwise re-list the whole pack to notice.
 */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const body = await readJson(request, MessengerRenditionsRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `messenger-renditions:${id}`,
      key,
      request: body,
    }, async () => ({
      status: 200,
      body: await bindMessengerRenditions(db, principal.sub, id, body),
    }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
