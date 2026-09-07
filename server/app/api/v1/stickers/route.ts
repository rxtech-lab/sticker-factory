import { and, eq, inArray } from "drizzle-orm";
import { assets } from "@/lib/db/schema";
import { isAppClipClient } from "@/lib/subscription/app-clip";
import { ApiError } from "@/lib/http/errors";
import { CreateStickerRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { requireSupportedIOSAppVersion } from "@/lib/http/ios-app-version";
import { integerQuery, textQuery } from "@/lib/http/query";
import { executeIdempotent, requireIdempotencyKey, RetryableIdempotencyError } from "@/lib/services/idempotency";
import { purgeStickerMediaImmediately } from "@/lib/services/assets";
import { createChatTurn, createSticker, listStickers } from "@/lib/services/stickers";
import { startGenerationWorkflow } from "@/lib/services/workflows";

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    requireSupportedIOSAppVersion(request, principal.clientId);
    const url = new URL(request.url);
    const kind = url.searchParams.get("kind");
    const status = url.searchParams.get("status");
    const result = await listStickers(db, principal.sub, {
      limit: integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 100, defaultValue: 30 }),
      cursor: url.searchParams.get("cursor"),
      kind: kind === "static" || kind === "animated" ? kind : undefined,
      status: status === "draft" || status === "published" ? status : undefined,
      query: textQuery(url.searchParams.get("q"), { name: "q", maxLength: 100 }),
    });
    return noStoreJson(result);
  });
}

export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, CreateStickerRequestSchema.parse);
    const appClip = isAppClipClient(principal) || body.useQuickModeAllowance === true;
    if (appClip && (body.kind !== "static" || !body.quick)) throw new ApiError(422, "APP_CLIP_QUICK_ONLY", "Choose static quick generation.");
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: "create-sticker",
      key,
      request: body,
    }, async () => {
      const created = await createSticker(db, principal.sub, body);
      let turn: Awaited<ReturnType<typeof createChatTurn>>;
      try {
        turn = await createChatTurn(db, principal.sub, created.stickerId, {
          text: body.prompt,
          intent: "generate",
          attachments: body.referenceAssetIds.map((assetId) => ({ assetId, kind: "reference" as const })),
          imagePlacement: "replace",
          quick: body.quick,
        }, appClip);
      } catch (error) {
        // A missing usage endpoint/item definitively rejected the operation before
        // a generation job or usage record existed. Keep uploaded inputs for a retry.
        const safeToRetry = error instanceof ApiError && error.code === "APP_CLIP_USAGE_NOT_CONFIGURED";
        let rolledBack = false;
        try {
          if (safeToRetry && body.referenceAssetIds.length > 0) {
            await db.update(assets).set({ stickerId: null }).where(and(
              eq(assets.ownerId, principal.sub), eq(assets.stickerId, created.stickerId),
              inArray(assets.id, body.referenceAssetIds),
            ));
          }
          await purgeStickerMediaImmediately(db, principal.sub, created.stickerId);
          rolledBack = true;
        } catch (cleanupError) {
          console.error("Failed to purge a partially created sticker", { stickerId: created.stickerId, cleanupError });
        }
        throw safeToRetry && rolledBack ? new RetryableIdempotencyError(error) : error;
      }
      let workflowRunId: string | null = null;
      let state: "queued" | "failed" = "queued";
      try {
        workflowRunId = await startGenerationWorkflow(db, turn.jobId);
      } catch {
        state = "failed";
      }
      return {
        status: 202,
        body: {
          ...created,
          initialMessageId: turn.messageId,
          initialMessageStatus: state === "failed" ? "failed" : "streaming",
          job: { id: turn.jobId, state, workflowRunId, retryable: state === "failed", eventsUrl: `/api/v1/jobs/${turn.jobId}/events` },
        },
      };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
