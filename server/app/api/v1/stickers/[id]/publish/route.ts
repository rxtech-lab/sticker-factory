import { and, desc, eq } from "drizzle-orm";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createExportJob } from "@/lib/services/stickers";
import { startQuickPublishWorkflow } from "@/lib/services/workflows";
import { quickPublishCreditCost } from "@/lib/subscription/pricing";

/**
 * Quick mode's publish: accept the outstanding candidate, render its exports on the server, bind
 * them.
 *
 * The counterpart to `POST /stickers/{id}/exports`, which binds renditions a client has already
 * rendered and uploaded. That endpoint stays the main app's path — it has the renderer, and its
 * output is authoritative. This one exists for the Messages extension, which has neither the code
 * nor the memory budget to render an export ladder, and would otherwise leave every sticker made
 * inside Messages as a draft nobody can send.
 *
 * Returns a job to watch, exactly like the client-rendered publish does. The render is far too slow
 * to hold a request open for.
 */
type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: `quick-publish:${id}`,
      key,
      request: { stickerId: id },
    }, async () => {
      // The hold is placed from the document's kind, because the request carries no rendition to
      // price. Read the candidate first and the active revision second: the candidate is what the
      // publish will accept and draw.
      const sticker = await db.select().from(stickers)
        .where(and(eq(stickers.id, id), eq(stickers.ownerId, principal.sub))).get();
      if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
      const candidate = await db.select().from(stickerRevisions).where(and(
        eq(stickerRevisions.stickerId, id),
        eq(stickerRevisions.candidateState, "candidate"),
      )).orderBy(desc(stickerRevisions.createdAt)).get();
      const target = candidate ?? (sticker.activeRevisionId
        ? await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, sticker.activeRevisionId)).get()
        : undefined);
      if (!target) throw new ApiError(409, "NO_REVISION_TO_PUBLISH", "This sticker has nothing to publish yet");

      const kind = StickerDocumentSchema.parse(target.documentJson).kind;
      const jobId = await createExportJob(db, principal.sub, id, quickPublishCreditCost(kind));
      let workflowRunId: string | null = null;
      let state: "queued" | "failed" = "queued";
      try {
        workflowRunId = await startQuickPublishWorkflow(db, jobId);
      } catch {
        state = "failed";
      }
      return {
        status: 202,
        body: {
          stickerId: id,
          revisionId: target.id,
          job: {
            id: jobId,
            state,
            workflowRunId,
            retryable: state === "failed",
            eventsUrl: `/api/v1/jobs/${jobId}/events`,
          },
        },
      };
    });
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
