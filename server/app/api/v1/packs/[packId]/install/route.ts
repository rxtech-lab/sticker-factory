import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { installPack, uninstallPack } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string }> };

/**
 * Both responses carry only `{ packId, installed }` — deliberately no install count.
 *
 * `executeIdempotent` stores the response body and replays it verbatim for 24 hours, so an
 * embedded count would go stale the moment anybody else installed the pack. Clients refetch the
 * detail instead.
 */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `install-pack:${packId}`,
      key,
      request: { packId },
    }, async () => ({ status: 200, body: await installPack(db, principal.sub, packId) }));
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
      operation: `uninstall-pack:${packId}`,
      key,
      request: { packId },
    }, async () => ({ status: 200, body: await uninstallPack(db, principal.sub, packId) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
