import { UpdateStickerRequestSchema } from "@/lib/contracts/api";
import { clientDocumentVersion } from "@/lib/contracts/sticker";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createCleanupJob, downcastStickerDetail, getSticker, updateSticker } from "@/lib/services/stickers";
import { startCleanupWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const detail = await getSticker(db, principal.sub, id);
    return noStoreJson(downcastStickerDetail(detail, clientDocumentVersion(request)));
  });
}

export async function PATCH(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const body = await readJson(request, UpdateStickerRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `update-sticker:${id}`,
      key,
      request: body,
    }, async () => ({ status: 200, body: await updateSticker(db, principal.sub, id, body) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}

export async function DELETE(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `delete-sticker:${id}`,
      key,
      request: { id },
    }, async () => {
      const jobId = await createCleanupJob(db, principal.sub, id);
      let workflowRunId: string | null = null;
      let state: "queued" | "failed" = "queued";
      try {
        workflowRunId = await startCleanupWorkflow(db, jobId);
      } catch {
        state = "failed";
      }
      return { status: 202, body: { stickerId: id, status: state === "failed" ? "delete_failed" : "deleting", job: { id: jobId, state, workflowRunId, retryable: state === "failed" } } };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
