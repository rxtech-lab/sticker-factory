import { AddPackItemRequestSchema, ReorderPackItemsRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { addPackItem, reorderPackItems } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string }> };

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const body = await readJson(request, AddPackItemRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `add-pack-item:${packId}`,
      key,
      request: body,
    }, async () => ({
      status: 200,
      body: await addPackItem(db, principal.sub, packId, body.stickerId, body.position),
    }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}

/** Replace the whole membership in one call — this is both "set items" and "reorder". */
export async function PUT(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const body = await readJson(request, ReorderPackItemsRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `set-pack-items:${packId}`,
      key,
      request: body,
    }, async () => ({ status: 200, body: await reorderPackItems(db, principal.sub, packId, body.stickerIds) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
