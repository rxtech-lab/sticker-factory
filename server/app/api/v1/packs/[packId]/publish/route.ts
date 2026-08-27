import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { publishPack } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string }> };

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `publish-pack:${packId}`,
      key,
      request: { packId },
    }, async () => ({ status: 200, body: await publishPack(db, principal.sub, packId) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
