import { ImportStickerRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { importSticker } from "@/lib/services/stickers";

/**
 * Creates a static sticker project from an image the client already holds, without generating.
 *
 * The static segment sits ahead of `[id]` in the route tree, so `/stickers/import` never resolves
 * as a sticker id.
 *
 * 201 rather than the 202 `POST /stickers` returns: nothing is queued, so there is no job to watch
 * and the project is complete when the response lands.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, ImportStickerRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: "import-sticker",
      key,
      request: body,
    }, async () => ({
      status: 201,
      body: await importSticker(db, principal.sub, body),
    }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
