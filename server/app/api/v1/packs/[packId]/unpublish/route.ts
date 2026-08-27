import { UnpublishPackRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { unpublishPack } from "@/lib/services/packs";

type Context = { params: Promise<{ packId: string }> };

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { packId } = await context.params;
    const body = await readJson(request, UnpublishPackRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `unpublish-pack:${packId}`,
      key,
      request: body,
    }, async () => ({ status: 200, body: await unpublishPack(db, principal.sub, packId, body.state) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
