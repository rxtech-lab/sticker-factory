import { CreateUploadRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createUpload } from "@/lib/services/assets";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";

export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, CreateUploadRequestSchema.parse);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation: "create-upload", key: requireIdempotencyKey(request), request: body }, async () => ({
      status: 201,
      body: await createUpload(db, principal.sub, body),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
