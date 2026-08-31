import { CreateUploadRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createUpload } from "@/lib/services/assets";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";

export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db, context) => {
    const body = await readJson(request, CreateUploadRequestSchema.parse);
    context.log("upload-intent.validated", {
      stickerId: body.stickerId ?? null,
      kind: body.kind,
      mimeType: body.mimeType,
      byteSize: body.byteSize,
      filenameLength: body.filename.length,
      sha256: body.sha256 ? "present" : "missing",
      sequence: body.sequence ?? null,
    });
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation: "create-upload", key: requireIdempotencyKey(request), request: body }, async () => ({
      status: 201,
      body: await createUpload(db, principal.sub, body),
    }));
    context.log("upload-intent.completed", {
      assetId: result.body.asset.id,
      status: result.status,
      replayed: result.replayed,
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
