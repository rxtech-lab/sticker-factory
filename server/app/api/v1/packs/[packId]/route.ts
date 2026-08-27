import { UpdatePackRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { deletePack, getPack, updatePack } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string }> };

/** `packId` accepts either the uuid or the public slug, so a shared link resolves directly. */
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    return noStoreJson(await getPack(db, principal.sub, packId));
  });
}

export async function PATCH(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const body = await readJson(request, UpdatePackRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `update-pack:${packId}`,
      key,
      request: body,
    }, async () => ({ status: 200, body: await updatePack(db, principal.sub, packId, body) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}

export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `delete-pack:${packId}`,
      key,
      request: { packId },
    }, async () => ({ status: 200, body: await deletePack(db, principal.sub, packId) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
