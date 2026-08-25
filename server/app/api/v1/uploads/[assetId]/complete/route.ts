import { CompleteUploadRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { completeUpload } from "@/lib/services/assets";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";

type Context = { params: Promise<{ assetId: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { assetId } = await context.params;
    const body = await readJson(request, CompleteUploadRequestSchema.parse);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation: `complete-upload:${assetId}`, key: requireIdempotencyKey(request), request: body }, async () => ({
      status: 200,
      body: await completeUpload(db, principal.sub, assetId, body.sha256),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
