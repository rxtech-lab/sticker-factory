import { and, asc, count, desc, eq, gt, inArray, isNull, lt, lte, max, ne, or } from "drizzle-orm";
import type {
  CreateStickerRequest,
  PostChatMessageRequest,
  PublishExportsRequest,
  SaveEditedDocumentRequest,
} from "@/lib/contracts/api";
import { EXPORT_LOOP_HOLD_SECONDS, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import type { Database } from "@/lib/db/client";
import { previewAssetIdSql, previewAssets, systemAssets } from "@/lib/db/columns";
import {
  assets,
  chatAttachments,
  chatMessages,
  chatThreads,
  generationEvents,
  generationJobs,
  plans,
  stickerRevisions,
  stickers,
} from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getReadyOwnedAssets, serializeAsset } from "@/lib/services/assets";
import { loadPlansByIds, serializePlan } from "@/lib/services/plans";

const MAX_AI_INPUT_BYTES = 32 * 1024 * 1024;
const AI_REFERENCE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/webp"]);

export interface StickerCursor {
  updatedAt: string;
  id: string;
}

/**
 * Recognises the `generation_jobs_one_active_per_sticker` partial unique index firing, including
 * when the driver has wrapped it, so callers can turn it into a 409 rather than a 500.
 */
export function isActiveJobConstraint(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; current && depth < 5; depth += 1) {
    const message = current instanceof Error ? current.message : String(current);
    if (message.includes("generation_jobs_one_active_per_sticker")
      || message.includes("UNIQUE constraint failed: generation_jobs.sticker_id")) {
      return true;
    }
    current = typeof current === "object" && "cause" in current ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

function encodeCursor(cursor: StickerCursor): string {
  return Buffer.from(JSON.stringify(cursor)).toString("base64url");
}

function decodeCursor(cursor?: string | null): StickerCursor | undefined {
  if (!cursor) return undefined;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as StickerCursor;
    if (!value.updatedAt || !value.id) throw new Error();
    return value;
  } catch {
    throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is invalid");
  }
}

export async function assertOwnedSticker(db: Database, ownerId: string, stickerId: string) {
  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
  )).get();
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  return sticker;
}

/**
 * A sticker plus its active revision's system and preview assets, resolved in one statement.
 *
 * The database lives in a single region, so every extra `select` costs a full round trip from the
 * function. Walking sticker -> revision -> asset -> asset per row made a 30-item page 90+ chained
 * queries; the joins below keep it at one regardless of page size.
 */
export function selectStickerSummaries(db: Database) {
  return db.select({
    sticker: stickers,
    systemAsset: systemAssets,
    previewAsset: previewAssets,
  }).from(stickers)
    .leftJoin(stickerRevisions, and(
      eq(stickerRevisions.id, stickers.activeRevisionId),
      eq(stickerRevisions.stickerId, stickers.id),
    ))
    .leftJoin(systemAssets, eq(systemAssets.id, stickerRevisions.systemAssetId))
    .leftJoin(previewAssets, eq(previewAssets.id, previewAssetIdSql));
}

export type StickerSummaryRow = {
  sticker: typeof stickers.$inferSelect;
  systemAsset: typeof assets.$inferSelect | null;
  previewAsset: typeof assets.$inferSelect | null;
};

export function serializeStickerSummary({ sticker, systemAsset, previewAsset }: StickerSummaryRow) {
  return {
    id: sticker.id,
    title: sticker.title,
    kind: sticker.kind,
    status: sticker.status,
    activeRevisionId: sticker.activeRevisionId,
    createdAt: sticker.createdAt.toISOString(),
    updatedAt: sticker.updatedAt.toISOString(),
    previewAsset: previewAsset ? serializeAsset(previewAsset) : null,
    systemSticker: systemAsset ? {
      assetId: systemAsset.id,
      mimeType: systemAsset.mimeType,
      byteSize: systemAsset.byteSize,
      sha256: systemAsset.sha256,
    } : null,
  };
}

async function serializeSticker(db: Database, sticker: typeof stickers.$inferSelect) {
  const row = await selectStickerSummaries(db).where(eq(stickers.id, sticker.id)).get();
  return serializeStickerSummary(row ?? { sticker, systemAsset: null, previewAsset: null });
}

export async function listStickers(
  db: Database,
  ownerId: string,
  options: { limit?: number; cursor?: string | null; kind?: "static" | "animated"; status?: "draft" | "published" } = {},
) {
  const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
  const cursor = decodeCursor(options.cursor);
  const conditions = [eq(stickers.ownerId, ownerId), ne(stickers.status, "deleting")];
  if (options.kind) conditions.push(eq(stickers.kind, options.kind));
  if (options.status) conditions.push(eq(stickers.status, options.status));
  if (cursor) conditions.push(or(
    lt(stickers.updatedAt, new Date(cursor.updatedAt)),
    and(eq(stickers.updatedAt, new Date(cursor.updatedAt)), lt(stickers.id, cursor.id)),
  )!);
  const rows = await selectStickerSummaries(db).where(and(...conditions))
    .orderBy(desc(stickers.updatedAt), desc(stickers.id)).limit(limit + 1);
  const page = rows.slice(0, limit);
  return {
    data: page.map(serializeStickerSummary),
    nextCursor: rows.length > limit && page.length > 0
      ? encodeCursor({ updatedAt: page.at(-1)!.sticker.updatedAt.toISOString(), id: page.at(-1)!.sticker.id })
      : null,
  };
}

export async function createSticker(db: Database, ownerId: string, request: CreateStickerRequest) {
  const references = await getReadyOwnedAssets(db, ownerId, request.referenceAssetIds);
  if (references.some((asset) => asset.kind !== "reference" && asset.kind !== "chat_attachment")) {
    throw new ApiError(422, "INVALID_REFERENCE", "Initial references must be reference image assets");
  }
  if (references.some((asset) => !AI_REFERENCE_MIME_TYPES.has(asset.mimeType))) {
    throw new ApiError(422, "INVALID_REFERENCE", "Initial references must be PNG, JPEG, or WebP images");
  }
  if (references.reduce((total, asset) => total + (asset.byteSize ?? 0), 0) > MAX_AI_INPUT_BYTES) {
    throw new ApiError(422, "AI_INPUT_TOO_LARGE", "Combined AI image inputs must not exceed 32 MB");
  }
  if (references.some((asset) => asset.stickerId !== null)) {
    throw new ApiError(422, "REFERENCE_ALREADY_ATTACHED", "An initial reference is already attached to another sticker");
  }
  const stickerId = crypto.randomUUID();
  const threadId = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.insert(stickers).values({
      id: stickerId,
      ownerId,
      title: request.title,
      kind: request.kind,
      status: "draft",
      createdAt: now,
      updatedAt: now,
    });
    await tx.insert(chatThreads).values({ id: threadId, stickerId, ownerId, createdAt: now, updatedAt: now });
    if (request.referenceAssetIds.length > 0) {
      const claimed = await tx.update(assets).set({ stickerId }).where(and(
        eq(assets.ownerId, ownerId),
        isNull(assets.stickerId),
        inArray(assets.id, request.referenceAssetIds),
      )).returning({ id: assets.id });
      if (claimed.length !== request.referenceAssetIds.length) {
        throw new ApiError(409, "REFERENCE_ALREADY_ATTACHED", "An initial reference was concurrently attached to another sticker");
      }
    }
  });
  return { stickerId, threadId };
}

export async function createExportJob(db: Database, ownerId: string, stickerId: string) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const id = crypto.randomUUID();
  try {
    await db.transaction(async (tx) => {
      const now = new Date();
      await tx.insert(generationJobs).values({
        id,
        ownerId,
        stickerId,
        kind: "export",
        state: "queued",
        createdAt: now,
        updatedAt: now,
      });
      await tx.insert(generationEvents).values({ jobId: id, ownerId, type: "queued", dataJson: { kind: "export" }, createdAt: now });
    });
  } catch (error) {
    if (isActiveJobConstraint(error)) {
      throw new ApiError(409, "AI_TURN_IN_PROGRESS", "Wait for the current sticker operation to finish");
    }
    throw error;
  }
  return id;
}

export async function createCleanupJob(db: Database, ownerId: string, stickerId: string) {
  const sticker = await db.select().from(stickers).where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId))).get();
  if (!sticker) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  if (sticker.status === "deleting") return retryFailedCleanupJob(db, ownerId, stickerId);
  if (sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  const active = await db.select({ id: generationJobs.id }).from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    inArray(generationJobs.state, ["queued", "running", "waiting"]),
  )).get();
  if (active) throw new ApiError(409, "STICKER_OPERATION_IN_PROGRESS", "Wait for the current sticker operation before deleting this project");
  const id = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.update(stickers).set({ status: "deleting", deletedAt: now, updatedAt: now }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
    ));
    await tx.insert(generationJobs).values({
      id,
      ownerId,
      stickerId,
      kind: "cleanup",
      priorStickerStatus: sticker.status === "published" ? "published" : "draft",
      state: "queued",
      createdAt: now,
      updatedAt: now,
    });
    await tx.insert(generationEvents).values({ jobId: id, ownerId, type: "queued", dataJson: { kind: "cleanup" }, createdAt: now });
  });
  return id;
}

export async function retryFailedCleanupJob(db: Database, ownerId: string, stickerId: string): Promise<string> {
  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
    eq(stickers.status, "deleting"),
  )).get();
  if (!sticker) throw new ApiError(404, "STICKER_NOT_FOUND", "Deleting sticker not found");
  const job = await db.select().from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    eq(generationJobs.ownerId, ownerId),
    eq(generationJobs.kind, "cleanup"),
    eq(generationJobs.state, "failed"),
    gt(generationJobs.attempts, 0),
  )).orderBy(desc(generationJobs.updatedAt)).get();
  if (!job) throw new ApiError(409, "CLEANUP_NOT_RETRYABLE", "The cleanup is not in a retryable failed state");
  if (job.attempts >= 5) throw new ApiError(409, "CLEANUP_RETRY_LIMIT", "Cleanup requires operator reconciliation after five attempts");
  const now = new Date();
  await db.transaction(async (tx) => {
    const changed = await tx.update(generationJobs).set({
      state: "queued",
      errorCode: null,
      errorMessage: null,
      completedAt: null,
      updatedAt: now,
    }).where(and(
      eq(generationJobs.id, job.id),
      eq(generationJobs.state, "failed"),
      eq(generationJobs.attempts, job.attempts),
    )).returning({ id: generationJobs.id });
    if (changed.length !== 1) throw new ApiError(409, "CLEANUP_RETRY_CLAIMED", "Another cleanup retry already started");
    await tx.insert(generationEvents).values({
      jobId: job.id,
      ownerId,
      type: "queued",
      dataJson: { kind: "cleanup", retryAttempt: job.attempts + 1 },
      createdAt: now,
    });
  });
  return job.id;
}

export async function requeueFailedCleanupJobs(
  db: Database,
  options: { limit?: number; olderThan?: Date } = {},
): Promise<Array<{ jobId: string; ownerId: string }>> {
  const limit = Math.min(Math.max(options.limit ?? 20, 1), 50);
  const olderThan = options.olderThan ?? new Date(Date.now() - 5 * 60 * 1000);
  const candidates = await db.select().from(generationJobs).where(and(
    eq(generationJobs.kind, "cleanup"),
    eq(generationJobs.state, "failed"),
    gt(generationJobs.attempts, 0),
    lt(generationJobs.attempts, 5),
    lte(generationJobs.updatedAt, olderThan),
  )).orderBy(asc(generationJobs.updatedAt)).limit(limit);
  const claimed: Array<{ jobId: string; ownerId: string }> = [];
  for (const candidate of candidates) {
    try {
      const jobId = await retryFailedCleanupJob(db, candidate.ownerId, candidate.stickerId);
      claimed.push({ jobId, ownerId: candidate.ownerId });
    } catch (error) {
      if (!(error instanceof ApiError) || error.status >= 500) throw error;
    }
  }
  return claimed;
}

export async function getSticker(db: Database, ownerId: string, stickerId: string) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const revisions = await db.select().from(stickerRevisions)
    .where(eq(stickerRevisions.stickerId, stickerId)).orderBy(desc(stickerRevisions.createdAt));
  return {
    ...(await serializeSticker(db, sticker)),
    revisions: revisions.map((revision) => ({
      id: revision.id,
      parentRevisionId: revision.parentRevisionId,
      sourceMessageId: revision.sourceMessageId,
      candidateState: revision.candidateState,
      document: StickerDocumentSchema.parse(revision.documentJson),
      masterAssetId: revision.masterAssetId,
      previewAssetId: revision.previewAssetId,
      pngAssetId: revision.pngAssetId,
      gifAssetId: revision.gifAssetId,
      mp4AssetId: revision.mp4AssetId,
      systemAssetId: revision.systemAssetId,
      createdAt: revision.createdAt.toISOString(),
      decidedAt: revision.decidedAt?.toISOString() ?? null,
    })),
  };
}

function intentToJobKind(intent: PostChatMessageRequest["intent"]) {
  if (intent === "generate") return "image" as const;
  if (intent === "animate") return "animation" as const;
  if (intent === "chat") return "chat" as const;
  return "edit" as const;
}

function revisionHasPublishedExports(revision: typeof stickerRevisions.$inferSelect): boolean {
  return Boolean(revision.systemAssetId && (revision.kind === "static"
    ? revision.pngAssetId
    : revision.gifAssetId && revision.mp4AssetId));
}

/** A play-once export has no repeat to separate, so nothing is held. */
function exportHoldSeconds(loop: StickerDocument["loop"]): number {
  return loop === "once" ? 0 : EXPORT_LOOP_HOLD_SECONDS;
}

/** What an export of `document` occupies on a timeline: the motion cycle plus the loop hold. */
export function expectedRenditionDuration(document: Extract<StickerDocument, { kind: "animated" }>): number {
  return document.durationSeconds * (document.loop === "pingPong" ? 2 : 1) + exportHoldSeconds(document.loop);
}

export function validateAnimatedRenditionTiming(
  document: Extract<StickerDocument, { kind: "animated" }>,
  rendition: Pick<typeof assets.$inferSelect, "kind" | "frameCount" | "durationSeconds" | "fps">,
): void {
  if (!rendition.frameCount || !rendition.durationSeconds || !rendition.fps) {
    throw new ApiError(422, "EXPORT_TIMING_UNVERIFIED", "Every animated rendition must have verified frame timing metadata");
  }
  // `speed` divides elapsed time on the way into the interpolator rather than rewriting keyframes,
  // so a document at 2x plays its authored duration in half the wall clock. Exports are wall clock,
  // so the cycle they must match is the authored duration divided by speed — missing this rejects
  // every correctly rendered export of a document that is not playing at 1x.
  const playbackSeconds = document.durationSeconds / Math.max(document.speed, 0.0001);
  const cycleSeconds = playbackSeconds * (document.loop === "pingPong" ? 2 : 1);
  const expectedDuration = cycleSeconds + exportHoldSeconds(document.loop);

  // The hold is extra display time on a frame that already exists, so the frame grid still spans
  // exactly the motion cycle. Inspection reports fps as frameCount/durationSeconds, which the hold
  // drags below the grid the frames were rendered on — recover the grid before comparing to it.
  const gridFps = rendition.frameCount / cycleSeconds;

  // gif and mp4 are rendered at the document's own fps. The system rendition walks a quality ladder
  // to fit under 500 KB, so it is a range rather than a value. The bottom of that ladder is 4 fps —
  // `SystemStickerPreset.adaptive` in `StickerGeniOS/Rendering/StickerExporter.swift` — because a
  // long cycle of dense art that cannot fit at 8 is better shipped choppy than shipped as a still.
  const fpsMatches = rendition.kind === "system"
    ? gridFps >= Math.min(document.fps, 4) - 0.5 && gridFps <= document.fps + 0.75
    : Math.abs(gridFps - document.fps) <= 0.75;
  if (!fpsMatches) throw new ApiError(422, "EXPORT_FPS_MISMATCH", "Animated rendition FPS does not match the accepted document");

  // Only the ladder renditions get to pick their own grid, so everything else has an exact count to
  // hit. This is what catches a frame dropped or duplicated at the ends of the cycle.
  if (rendition.kind !== "system" && Math.abs(rendition.frameCount - Math.ceil(cycleSeconds * document.fps)) > 1.01) {
    throw new ApiError(422, "EXPORT_FRAME_COUNT_MISMATCH", "Animated rendition frame count does not match the accepted document cycle");
  }
  const durationTolerance = 1 / gridFps + 0.01;
  if (Math.abs(rendition.durationSeconds - expectedDuration) > durationTolerance) {
    throw new ApiError(422, "EXPORT_DURATION_MISMATCH", "Animated rendition duration does not match the accepted document cycle and loop hold");
  }
}

export async function validateDocumentAssetReferences(
  db: Database,
  ownerId: string,
  stickerId: string,
  document: StickerDocument,
  additionalAssetIds: string[] = [],
): Promise<Map<string, typeof assets.$inferSelect>> {
  const imageLayers = document.layers.filter((layer): layer is Extract<typeof layer, { type: "image" }> => layer.type === "image");
  // v2 grew two more places a document can name an asset. Both are ownership holes if missed: an
  // svg layer can reference uploaded artwork, and the artwork background can reference an image.
  const svgAssetIds = document.layers.flatMap((layer) => (
    layer.type === "svg" && layer.source.kind === "asset" ? [layer.source.assetId] : []
  ));
  const backgroundAssetIds = document.background.type === "image" ? [document.background.assetId] : [];
  const ids = [...new Set([
    ...additionalAssetIds,
    ...imageLayers.flatMap((layer) => [layer.assetId, ...(layer.maskAssetId ? [layer.maskAssetId] : [])]),
    ...svgAssetIds,
    ...backgroundAssetIds,
  ])];
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "A document asset belongs to another sticker");
  }
  for (const layer of imageLayers) {
    const image = byId.get(layer.assetId)!;
    if (!new Set(["master", "preview", "reference", "chat_attachment"]).has(image.kind)
      || !AI_REFERENCE_MIME_TYPES.has(image.mimeType)) {
      throw new ApiError(422, "INVALID_LAYER_ASSET", "Image layers must reference ready project image assets");
    }
    if (layer.maskAssetId) {
      const mask = byId.get(layer.maskAssetId)!;
      if (mask.kind !== "mask" || !mask.hasAlpha || (mask.mimeType !== "image/png" && mask.mimeType !== "image/webp")) {
        throw new ApiError(422, "INVALID_LAYER_MASK", "Layer masks must reference validated project mask assets");
      }
      if (mask.width !== image.width || mask.height !== image.height || mask.mimeType !== image.mimeType) {
        throw new ApiError(422, "MASK_DIMENSIONS_MISMATCH", "Layer masks must match their image format and dimensions");
      }
    }
  }
  return byId;
}

/**
 * Why animation may not build on a base revision, or `undefined` when it may. Every rejection is a
 * `reason` code plus the values that produced it, because the user-facing consequence — "accept the
 * sticker first" — is only correct for one of them, and the rest are indistinguishable from outside.
 */
async function animationBaseRejection(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<{ reason: string; detail?: Record<string, unknown> } | undefined> {
  if (!baseRevision) return { reason: "no_base_revision" };
  if (baseRevision.stickerId !== sticker.id) {
    return { reason: "base_revision_other_sticker", detail: { baseStickerId: baseRevision.stickerId } };
  }
  if (baseRevision.kind !== "animated") return { reason: "base_revision_not_animated" };
  // A version the user already turned down, or one a later accept swept aside. Acceptance is no
  // longer the gate, so staleness has to be refused in its own right rather than falling out of it.
  if (baseRevision.candidateState !== "accepted" && baseRevision.candidateState !== "candidate") {
    return { reason: "base_revision_decided", detail: { candidateState: baseRevision.candidateState } };
  }
  // Nothing has been kept yet, so the project is a single live branch and this candidate is all
  // there is. This is the "generate, look at it, ask for motion" case: waiting for an accept would
  // make the user decide about the artwork before they are allowed to see it move.
  if (!sticker.activeRevisionId) return undefined;
  const activeRevisionId = sticker.activeRevisionId;
  const active = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, activeRevisionId),
    eq(stickerRevisions.stickerId, sticker.id),
  )).get();
  if (!active) return { reason: "active_revision_missing", detail: { activeRevisionId } };
  if (active.candidateState !== "accepted") {
    return { reason: "active_revision_not_accepted", detail: { activeCandidateState: active.candidateState } };
  }
  if (active.kind !== "animated") return { reason: "active_revision_not_animated", detail: { activeKind: active.kind } };
  if (baseRevision.id === active.id) return undefined;

  // Walk the parents back to the kept revision. Every hop must still be a live candidate — that is
  // what stops a request branching off a version the user has already turned down. What produced
  // each hop no longer matters: a candidate from a generate, an edit, or a plan build is as
  // animatable as one from an earlier animation turn.
  let current: typeof stickerRevisions.$inferSelect = baseRevision;
  const visited = new Set<string>();
  const walked: string[] = [];
  for (let depth = 0; depth < 32 && current.id !== active.id; depth += 1) {
    walked.push(current.id);
    if (visited.has(current.id)) return { reason: "parent_chain_cycle", detail: { walked } };
    if (current.candidateState !== "candidate") {
      return { reason: "chain_revision_not_candidate", detail: { walked, candidateState: current.candidateState } };
    }
    if (!current.parentRevisionId) return { reason: "chain_revision_has_no_parent", detail: { walked } };
    visited.add(current.id);
    const parent = await db.select().from(stickerRevisions).where(and(
      eq(stickerRevisions.id, current.parentRevisionId),
      eq(stickerRevisions.stickerId, sticker.id),
    )).get();
    if (!parent) return { reason: "parent_revision_missing", detail: { walked, parentRevisionId: current.parentRevisionId } };
    current = parent;
  }
  if (current.id !== active.id) return { reason: "parent_chain_depth_exceeded", detail: { walked } };
  return undefined;
}

/**
 * Whether animation may build on `baseRevision`: the kept revision, or a live candidate descended
 * from it — including a first generation nothing has been accepted from yet.
 *
 * Exposed as a predicate as well as the assertion below because the chat router decides to animate
 * from the user's words alone, with no view of what has been accepted. A turn it routes that way has
 * already been committed to the transcript, so it needs to ask the question and answer the user,
 * where a request carrying an explicit animate intent is simply rejected.
 */
export async function isValidAnimationBase(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<boolean> {
  const rejection = await animationBaseRejection(db, sticker, baseRevision);
  if (!rejection) return true;
  console.warn("Rejected an animation base", {
    ...rejection.detail,
    reason: rejection.reason,
    stickerId: sticker.id,
    stickerKind: sticker.kind,
    activeRevisionId: sticker.activeRevisionId,
    baseRevisionId: baseRevision?.id,
    baseRevisionKind: baseRevision?.kind,
    baseRevisionCandidateState: baseRevision?.candidateState,
    baseRevisionParentId: baseRevision?.parentRevisionId,
    baseRevisionSourceMessageId: baseRevision?.sourceMessageId,
  });
  return false;
}

export async function assertValidAnimationBase(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<void> {
  if (await isValidAnimationBase(db, sticker, baseRevision)) return;
  // The code is unchanged on purpose: clients key on it, and "not accepted" is still the shape of
  // the failure even though acceptance itself is no longer what is being asserted.
  throw new ApiError(
    422,
    "ANIMATION_BASE_NOT_ACCEPTED",
    "Animation must build on a live revision of this sticker: the current one, or a candidate descended from it",
  );
}

export async function createChatTurn(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PostChatMessageRequest,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const thread = await db.select().from(chatThreads).where(and(
    eq(chatThreads.stickerId, stickerId),
    eq(chatThreads.ownerId, ownerId),
  )).get();
  if (!thread) throw new ApiError(500, "CHAT_THREAD_MISSING", "Sticker chat thread is missing");

  const assetIds = request.attachments.map((attachment) => attachment.assetId);
  const attachedAssets = await getReadyOwnedAssets(db, ownerId, assetIds);
  const byId = new Map(attachedAssets.map((asset) => [asset.id, asset]));
  const baseRevision = request.baseRevisionId
    ? await db.select().from(stickerRevisions).where(and(
      eq(stickerRevisions.id, request.baseRevisionId),
      eq(stickerRevisions.stickerId, stickerId),
    )).get()
    : sticker.activeRevisionId
      ? await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, sticker.activeRevisionId)).get()
      : undefined;
  if (request.baseRevisionId && !baseRevision) {
    throw new ApiError(422, "INVALID_BASE_REVISION", "The selected base revision does not belong to this sticker");
  }
  const baseDocument = baseRevision ? StickerDocumentSchema.parse(baseRevision.documentJson) : undefined;
  if (request.intent === "animate") await assertValidAnimationBase(db, sticker, baseRevision);
  if (request.targetLayerId) {
    const target = baseDocument?.layers.find((layer) => layer.id === request.targetLayerId);
    if (!target) throw new ApiError(422, "INVALID_TARGET_LAYER", "The selected target layer does not exist in the base revision");
    // Any layer type is a legal edit target: an edit turn owns the whole layer stack, not just the
    // drawn artwork, so pointing at a caption to have it removed or reworded is an ordinary edit.
    // A masked edit is the one that still needs artwork underneath it, and the mask block below
    // enforces that on its own.
  }
  for (const attachment of request.attachments) {
    const asset = byId.get(attachment.assetId)!;
    if (attachment.kind === "mask" && asset.kind !== "mask") {
      throw new ApiError(422, "INVALID_MASK", "Mask attachments must reference a validated mask asset");
    }
    if (attachment.kind === "mask" && (
      (asset.mimeType !== "image/png" && asset.mimeType !== "image/webp")
      || !asset.hasAlpha
    )) {
      throw new ApiError(422, "INVALID_MASK", "Masks must be validated PNG or WebP images with alpha");
    }
    if (attachment.kind === "reference" && (
      (asset.kind !== "reference" && asset.kind !== "chat_attachment")
      || !AI_REFERENCE_MIME_TYPES.has(asset.mimeType)
    )) {
      throw new ApiError(422, "INVALID_REFERENCE", "Chat references must be PNG, JPEG, or WebP reference images");
    }
    if (asset.stickerId && asset.stickerId !== stickerId) {
      throw new ApiError(422, "ASSET_STICKER_MISMATCH", "An attachment belongs to another sticker");
    }
  }
  const selectedTarget = baseDocument?.layers.find((layer) => layer.type === "image" && (
    request.targetLayerId ? layer.id === request.targetLayerId : true
  ));
  const selectedTargetAsset = request.intent === "edit" && request.imagePlacement !== "add" && selectedTarget?.type === "image"
    ? await getReadyOwnedAssets(db, ownerId, [selectedTarget.assetId]).then((items) => items[0])
    : undefined;
  const totalAiInputBytes = attachedAssets.reduce((total, asset) => total + (asset.byteSize ?? 0), 0)
    + (selectedTargetAsset?.byteSize ?? 0);
  if (totalAiInputBytes > MAX_AI_INPUT_BYTES) {
    throw new ApiError(422, "AI_INPUT_TOO_LARGE", "Combined AI image inputs must not exceed 32 MB");
  }
  const maskAttachments = request.attachments.filter((attachment) => attachment.kind === "mask");
  if (maskAttachments.length > 1) {
    throw new ApiError(422, "TOO_MANY_MASKS", "One edit may contain at most one mask");
  }
  if (maskAttachments.length === 1) {
    if (!baseRevision || !baseDocument) throw new ApiError(422, "MASK_TARGET_REQUIRED", "A mask requires an existing image layer");
    const document = baseDocument;
    const requestedLayerId = maskAttachments[0].targetLayerId ?? request.targetLayerId;
    const targetLayer = document.layers.find((layer) => layer.type === "image" && (!requestedLayerId || layer.id === requestedLayerId));
    if (!targetLayer || targetLayer.type !== "image") throw new ApiError(422, "MASK_TARGET_REQUIRED", "The target image layer does not exist");
    const targetAsset = await getReadyOwnedAssets(db, ownerId, [targetLayer.assetId]).then((items) => items[0]);
    const maskAsset = byId.get(maskAttachments[0].assetId)!;
    if (maskAsset.mimeType !== targetAsset.mimeType || maskAsset.width !== targetAsset.width || maskAsset.height !== targetAsset.height) {
      throw new ApiError(422, "MASK_DIMENSIONS_MISMATCH", "The mask and target image must have the same format and dimensions");
    }
  }
  if (request.intent === "animate" && sticker.kind !== "animated") {
    throw new ApiError(422, "STATIC_STICKER_CANNOT_ANIMATE", "This sticker was created in static mode");
  }

  const messageId = crypto.randomUUID();
  const jobId = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
      .where(eq(chatMessages.threadId, thread.id)).get();
    const sequence = (sequenceRow?.value ?? 0) + 1;
    try {
      await tx.insert(generationJobs).values({
        id: jobId,
        ownerId,
        stickerId,
        sourceMessageId: messageId,
        kind: intentToJobKind(request.intent),
        state: "queued",
        createdAt: now,
        updatedAt: now,
      });
    } catch (error) {
      if (isActiveJobConstraint(error)) {
        throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
      }
      throw error;
    }
    await tx.insert(chatMessages).values({
      id: messageId,
      threadId: thread.id,
      ownerId,
      role: "user",
      kind: request.intent === "animate"
        ? "animation"
        : request.intent === "edit"
          ? "image_edit"
          : request.intent === "generate"
            ? "image"
            : "text",
      content: request.text,
      targetLayerId: request.targetLayerId,
      baseRevisionId: baseRevision?.id,
      imagePlacement: request.imagePlacement,
      sequence,
      jobId,
      status: "streaming",
      createdAt: now,
    });
    if (request.attachments.length > 0) {
      await tx.insert(chatAttachments).values(request.attachments.map((attachment, position) => ({
        messageId,
        assetId: attachment.assetId,
        kind: attachment.kind,
        targetLayerId: attachment.targetLayerId ?? request.targetLayerId,
        position,
      })));
      const expectedClaims = attachedAssets.filter((asset) => asset.stickerId === null).length;
      const claimed = await tx.update(assets).set({ stickerId }).where(and(
        eq(assets.ownerId, ownerId),
        isNull(assets.stickerId),
        inArray(assets.id, assetIds),
      )).returning({ id: assets.id });
      if (claimed.length !== expectedClaims) {
        throw new ApiError(409, "ASSET_ALREADY_ATTACHED", "An attachment was concurrently claimed by another sticker");
      }
    }
    await tx.update(chatThreads).set({ updatedAt: now }).where(eq(chatThreads.id, thread.id));
    await tx.update(stickers).set({ updatedAt: now }).where(eq(stickers.id, stickerId));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId,
      type: "queued",
      dataJson: { intent: request.intent, messageId },
      createdAt: now,
    });
  });
  return { sticker, messageId, jobId };
}

export async function retryFailedChatTurn(
  db: Database,
  ownerId: string,
  stickerId: string,
  sourceMessageId: string,
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const thread = await db.select().from(chatThreads).where(and(
    eq(chatThreads.stickerId, stickerId),
    eq(chatThreads.ownerId, ownerId),
  )).get();
  if (!thread) throw new ApiError(404, "CHAT_NOT_FOUND", "Chat not found");
  const message = await db.select().from(chatMessages).where(and(
    eq(chatMessages.id, sourceMessageId),
    eq(chatMessages.threadId, thread.id),
    eq(chatMessages.ownerId, ownerId),
    eq(chatMessages.role, "user"),
  )).get();
  if (!message || !message.jobId) throw new ApiError(404, "MESSAGE_NOT_FOUND", "Retry source message not found");
  if (message.status !== "failed") throw new ApiError(409, "MESSAGE_NOT_RETRYABLE", "Only the latest failed AI turn can be retried");
  const original = await db.select().from(generationJobs).where(and(
    eq(generationJobs.id, message.jobId),
    eq(generationJobs.ownerId, ownerId),
    eq(generationJobs.stickerId, stickerId),
  )).get();
  if (!original || (original.state !== "failed" && original.state !== "cancelled")) {
    throw new ApiError(409, "JOB_NOT_RETRYABLE", "Only failed or cancelled AI turns can be retried");
  }
  const attempts = await db.select({ value: count() }).from(generationJobs)
    .where(and(eq(generationJobs.sourceMessageId, sourceMessageId), eq(generationJobs.ownerId, ownerId))).get();
  if ((attempts?.value ?? 0) >= 4) throw new ApiError(429, "RETRY_LIMIT_REACHED", "This AI turn has reached its retry limit");
  const jobId = crypto.randomUUID();
  try {
    await db.transaction(async (tx) => {
      const now = new Date();
      await tx.insert(generationJobs).values({
        id: jobId,
        ownerId,
        stickerId,
        sourceMessageId,
        kind: original.kind,
        state: "queued",
        createdAt: now,
        updatedAt: now,
      });
      await tx.insert(generationEvents).values({
        jobId,
        ownerId,
        type: "queued",
        dataJson: { retryOfJobId: original.id, sourceMessageId },
        createdAt: now,
      });
      const claimed = await tx.update(chatMessages).set({ jobId, status: "streaming" }).where(and(
        eq(chatMessages.id, sourceMessageId),
        eq(chatMessages.jobId, original.id),
        eq(chatMessages.status, "failed"),
      )).returning({ id: chatMessages.id });
      if (claimed.length !== 1) {
        throw new ApiError(409, "MESSAGE_NOT_RETRYABLE", "Another retry already claimed this failed AI turn");
      }
    });
  } catch (error) {
    if (isActiveJobConstraint(error)) {
      throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
    }
    throw error;
  }
  return { messageId: sourceMessageId, jobId };
}

export async function listChatMessages(
  db: Database,
  ownerId: string,
  stickerId: string,
  options: { afterSequence?: number; beforeSequence?: number; limit?: number; latest?: boolean } = {},
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const thread = await db.select().from(chatThreads).where(eq(chatThreads.stickerId, stickerId)).get();
  if (!thread || thread.ownerId !== ownerId) throw new ApiError(404, "CHAT_NOT_FOUND", "Chat not found");
  const limit = Math.min(options.limit ?? 100, 200);
  const newestFirst = options.beforeSequence !== undefined || Boolean(options.latest) || options.afterSequence === undefined;
  const rows = await db.select().from(chatMessages).where(and(
    eq(chatMessages.threadId, thread.id),
    options.afterSequence !== undefined ? gt(chatMessages.sequence, options.afterSequence) : undefined,
    options.beforeSequence !== undefined ? lt(chatMessages.sequence, options.beforeSequence) : undefined,
  )).orderBy(newestFirst ? desc(chatMessages.sequence) : asc(chatMessages.sequence)).limit(limit + 1);
  const hasOlder = newestFirst && rows.length > limit;
  const filtered = rows.slice(0, limit);
  if (newestFirst) filtered.reverse();
  const messageIds = filtered.map((row) => row.id);
  const attachments = messageIds.length
    ? await db.select().from(chatAttachments).where(inArray(chatAttachments.messageId, messageIds)).orderBy(asc(chatAttachments.position))
    : [];
  // Resolved through the message's own `planId` rather than by matching `plans.messageId`: one
  // plan is now shown many times, so the plan does not belong to a single message any more.
  const planRows = await loadPlansByIds(db, [...new Set(
    filtered.map((row) => row.planId).filter((id): id is string => id !== null),
  )]);
  return {
    data: filtered.map((message) => serializeChatMessage(
      message,
      attachments.filter((item) => item.messageId === message.id),
      planRows.find((plan) => plan.id === message.planId),
    )),
    nextBeforeSequence: hasOlder && filtered.length > 0 ? filtered[0].sequence : null,
  };
}

/**
 * The single client-facing shape for a chat message. Shared by the transcript endpoint and by
 * generation events, so a message delivered over the stream is byte-identical to the one a
 * refetch would return.
 */
export function serializeChatMessage(
  message: typeof chatMessages.$inferSelect,
  attachments: Array<typeof chatAttachments.$inferSelect> = [],
  plan?: typeof plans.$inferSelect,
) {
  return {
    // `planRevision` is what the card was rendering when it was posted, so a card from before the
    // agent revised the draft serializes as read-only rather than offering a stale Generate button.
    plan: plan ? serializePlan(plan, { atRevision: message.planRevision }) : undefined,
    id: message.id,
    role: message.role,
    kind: message.kind,
    content: message.content,
    targetLayerId: message.targetLayerId,
    baseRevisionId: message.baseRevisionId,
    imagePlacement: message.imagePlacement,
    sequence: message.sequence,
    revisionId: message.revisionId,
    jobId: message.jobId,
    status: message.status,
    createdAt: message.createdAt.toISOString(),
    attachments: attachments.map((item) => ({
      assetId: item.assetId,
      kind: item.kind,
      targetLayerId: item.targetLayerId,
    })),
  };
}

export async function acceptRevision(db: Database, ownerId: string, stickerId: string, revisionId: string) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (!revision) throw new ApiError(404, "REVISION_NOT_FOUND", "Revision not found");
  if (revision.candidateState === "accepted" && sticker.activeRevisionId === revisionId) {
    return { revisionId, candidateState: "accepted" as const, activeRevisionId: revisionId };
  }
  if (revision.candidateState !== "candidate") throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is no longer a candidate");
  const now = new Date();
  await db.transaction(async (tx) => {
    const changed = await tx.update(stickerRevisions).set({ candidateState: "accepted", decidedAt: now }).where(and(
      eq(stickerRevisions.id, revisionId),
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
    )).returning({ id: stickerRevisions.id });
    if (changed.length === 0) throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is no longer a candidate");
    await tx.update(stickerRevisions).set({ candidateState: "superseded", decidedAt: now }).where(and(
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
      ne(stickerRevisions.id, revisionId),
    ));
    await tx.update(stickers).set({
      activeRevisionId: revisionId,
      status: revisionHasPublishedExports(revision) ? "published" : "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });
  return { revisionId, candidateState: "accepted" as const, activeRevisionId: revisionId };
}

export async function rejectRevision(db: Database, ownerId: string, stickerId: string, revisionId: string) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const existing = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (existing?.candidateState === "rejected") return { revisionId, candidateState: "rejected" as const };
  const [revision] = await db.update(stickerRevisions).set({ candidateState: "rejected", decidedAt: new Date() })
    .where(and(
      eq(stickerRevisions.id, revisionId),
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
    )).returning();
  if (!revision) throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is missing or no longer a candidate");
  return { revisionId, candidateState: "rejected" as const };
}

export async function revertRevision(db: Database, ownerId: string, stickerId: string, revisionId: string, decisionId = crypto.randomUUID()) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const priorResult = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, decisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (priorResult) {
    return { revisionId: priorResult.id, revertedFromRevisionId: revisionId, activeRevisionId: priorResult.id };
  }
  const target = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (!target) throw new ApiError(404, "REVISION_NOT_FOUND", "Revision not found");
  const newRevisionId = decisionId;
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.insert(stickerRevisions).values({
      id: newRevisionId,
      stickerId,
      parentRevisionId: sticker.activeRevisionId,
      kind: target.kind,
      candidateState: "accepted",
      documentJson: StickerDocumentSchema.parse(target.documentJson),
      masterAssetId: target.masterAssetId,
      previewAssetId: target.previewAssetId,
      pngAssetId: target.pngAssetId,
      gifAssetId: target.gifAssetId,
      mp4AssetId: target.mp4AssetId,
      systemAssetId: target.systemAssetId,
      createdAt: now,
      decidedAt: now,
    });
    await tx.update(stickers).set({
      activeRevisionId: newRevisionId,
      status: revisionHasPublishedExports(target) ? "published" : "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });
  return { revisionId: newRevisionId, revertedFromRevisionId: revisionId, activeRevisionId: newRevisionId };
}

export async function createCandidateRevision(
  db: Database,
  input: {
    ownerId: string;
    stickerId: string;
    sourceMessageId: string;
    document: StickerDocument;
    id?: string;
    parentRevisionId?: string;
    masterAssetId?: string;
    previewAssetId?: string;
  },
) {
  const sticker = await assertOwnedSticker(db, input.ownerId, input.stickerId);
  const id = input.id ?? crypto.randomUUID();
  const parsed = StickerDocumentSchema.parse(input.document);
  if (parsed.kind !== sticker.kind) {
    throw new ApiError(422, "REVISION_KIND_MISMATCH", "Revision document kind must match the sticker project kind");
  }
  if (input.id) {
    const existing = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, input.id)).get();
    if (existing) {
      if (existing.stickerId !== input.stickerId || existing.sourceMessageId !== input.sourceMessageId) {
        throw new ApiError(409, "REVISION_ID_CONFLICT", "The deterministic revision ID belongs to another result");
      }
      return existing.id;
    }
  }
  if (input.parentRevisionId) {
    const parent = await db.select({ id: stickerRevisions.id }).from(stickerRevisions).where(and(
      eq(stickerRevisions.id, input.parentRevisionId),
      eq(stickerRevisions.stickerId, input.stickerId),
    )).get();
    if (!parent) throw new ApiError(422, "INVALID_PARENT_REVISION", "The revision parent does not belong to this sticker");
  }
  const assetIds = [input.masterAssetId, input.previewAssetId].filter((value): value is string => Boolean(value));
  const revisionAssets = await validateDocumentAssetReferences(db, input.ownerId, input.stickerId, parsed, assetIds);
  if (input.masterAssetId && revisionAssets.get(input.masterAssetId)?.kind !== "master") {
    throw new ApiError(422, "INVALID_MASTER_ASSET", "The revision master must reference a ready master asset");
  }
  await db.insert(stickerRevisions).values({
    id,
    stickerId: input.stickerId,
    parentRevisionId: input.parentRevisionId ?? sticker.activeRevisionId,
    sourceMessageId: input.sourceMessageId,
    kind: parsed.kind,
    candidateState: "candidate",
    documentJson: parsed,
    masterAssetId: input.masterAssetId,
    previewAssetId: input.previewAssetId,
    createdAt: new Date(),
  });
  return id;
}

/**
 * Saves a document edited on the client as a new, already-accepted revision.
 *
 * Modelled on `revertRevision` rather than `createCandidateRevision`: both insert a revision that
 * is decided the moment it exists, keyed on a deterministic id so a retry is a no-op. The
 * difference from a generated candidate is that there is nothing to review — the user already saw
 * exactly what they made — so there is no candidate gate to pass through.
 *
 * The immutability trigger is never fought: this only inserts, and the only columns it later
 * updates are `candidate_state`/`decided_at`, which the trigger does not guard.
 */
export async function saveEditedRevision(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: SaveEditedDocumentRequest,
  revisionId = crypto.randomUUID(),
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);

  // Deterministic-id replay. Callers pass `idempotencyUuid(...)`, so a save retried after a flaky
  // connection returns the revision it already made instead of forking the chain.
  const prior = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (prior) {
    return {
      revisionId: prior.id,
      parentRevisionId: prior.parentRevisionId,
      candidateState: prior.candidateState,
      createdAt: prior.createdAt.toISOString(),
      stickerStatus: sticker.status,
    };
  }

  // Nothing in the schema serialises an edit against a running generation — the one-active-job
  // index guards jobs, not revisions. Without this, an edit saved mid-generation is superseded by
  // whatever the workflow lands moments later, with no sign that it happened.
  const activeJob = await db.select({ id: generationJobs.id }).from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    inArray(generationJobs.state, ["queued", "running", "waiting"]),
  )).get();
  if (activeJob) {
    throw new ApiError(409, "STICKER_OPERATION_IN_PROGRESS", "Wait for the current sticker operation before saving an edit");
  }

  const document = StickerDocumentSchema.parse(request.document);
  if (document.kind !== sticker.kind) {
    throw new ApiError(422, "REVISION_KIND_MISMATCH", "Revision document kind must match the sticker project kind");
  }

  const parent = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.parentRevisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).get();
  if (!parent) throw new ApiError(422, "INVALID_PARENT_REVISION", "The revision parent does not belong to this sticker");
  // Editing forward from a branch that was already turned down would resurrect it silently.
  if (parent.candidateState === "rejected" || parent.candidateState === "superseded") {
    throw new ApiError(409, "INVALID_PARENT_REVISION", "That revision was already rejected or superseded");
  }

  await validateDocumentAssetReferences(db, ownerId, stickerId, document);

  const now = new Date();
  await db.transaction(async (tx) => {
    // The edit shows up in the transcript so no revision is orphaned from the history, but it is
    // posted as `device_edit` rather than as an ordinary turn: the user never said this, and a
    // bubble quoting words they did not type reads as a message the agent should answer. The app
    // draws the kind as a divider instead.
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, stickerId)).get();
    let sourceMessageId: string | undefined;
    if (thread) {
      const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
        .where(eq(chatMessages.threadId, thread.id)).get();
      sourceMessageId = crypto.randomUUID();
      await tx.insert(chatMessages).values({
        id: sourceMessageId,
        threadId: thread.id,
        ownerId,
        role: "user",
        kind: "device_edit",
        // Still the message's own text rather than something the client composes: it is what the
        // agent reads in the transcript on the next turn, and what the divider is labelled with.
        content: request.note?.trim() || "Edited on device",
        baseRevisionId: request.parentRevisionId,
        sequence: (sequenceRow?.value ?? 0) + 1,
        revisionId,
        status: "complete",
        createdAt: now,
      });
    }

    await tx.insert(stickerRevisions).values({
      id: revisionId,
      stickerId,
      parentRevisionId: request.parentRevisionId,
      sourceMessageId,
      kind: document.kind,
      // Accepted on arrival: the user already saw what they made, so a review gate would only ask
      // them to confirm their own edit.
      candidateState: "accepted",
      documentJson: document,
      createdAt: now,
      decidedAt: now,
    });

    // Mirrors `acceptRevision`: promoting one revision retires any candidate still waiting, or the
    // chat would keep offering to accept something the edit has already moved past.
    await tx.update(stickerRevisions).set({ candidateState: "superseded", decidedAt: now }).where(and(
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
      ne(stickerRevisions.id, revisionId),
    ));

    // An edited revision carries no renditions, so a previously published sticker drops back to
    // draft. That is correct — the published pixels no longer match the document — but it is
    // user-visible, which is why the app warns before saving over a published sticker.
    await tx.update(stickers).set({
      activeRevisionId: revisionId,
      status: "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });

  return {
    revisionId,
    parentRevisionId: request.parentRevisionId,
    candidateState: "accepted" as const,
    createdAt: now.toISOString(),
    stickerStatus: "draft" as const,
  };
}

export async function bindExports(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PublishExportsRequest,
  publishedRevisionId = crypto.randomUUID(),
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const existingPublished = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).get();
  if (existingPublished) {
    if (existingPublished.stickerId !== stickerId || existingPublished.parentRevisionId !== request.revisionId) {
      throw new ApiError(409, "PUBLISHED_REVISION_CONFLICT", "The deterministic published revision ID belongs to another export");
    }
    return { stickerId, revisionId: existingPublished.id, sourceRevisionId: request.revisionId, status: "published" as const };
  }
  if (sticker.activeRevisionId !== request.revisionId) {
    throw new ApiError(409, "REVISION_NOT_ACTIVE", "Exports may only be published for the active revision");
  }
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.revisionId),
    eq(stickerRevisions.stickerId, stickerId),
    eq(stickerRevisions.candidateState, "accepted"),
  )).get();
  if (!revision) throw new ApiError(409, "REVISION_NOT_ACCEPTED", "The revision must be accepted before publishing");
  const ids = [request.pngAssetId, request.gifAssetId, request.mp4AssetId, request.systemAssetId].filter((value): value is string => Boolean(value));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "An export belongs to another sticker");
  }
  const system = byId.get(request.systemAssetId)!;
  if (system.kind !== "system" || (system.byteSize ?? Infinity) >= 500_000) {
    throw new ApiError(422, "INVALID_SYSTEM_STICKER", "A verified system rendition below 500 KB is required");
  }
  if (request.gifAssetId && byId.get(request.gifAssetId)?.kind !== "gif") throw new ApiError(422, "INVALID_GIF_EXPORT", "GIF export asset is invalid");
  if (request.mp4AssetId && byId.get(request.mp4AssetId)?.kind !== "mp4") throw new ApiError(422, "INVALID_MP4_EXPORT", "MP4 export asset is invalid");
  if (request.pngAssetId && byId.get(request.pngAssetId)?.kind !== "master") throw new ApiError(422, "INVALID_PNG_EXPORT", "PNG export asset is invalid");
  if (revision.kind === "static" && !request.pngAssetId) throw new ApiError(422, "PNG_EXPORT_REQUIRED", "Static stickers require a rendered PNG export");
  if (revision.kind === "static" && (request.gifAssetId || request.mp4AssetId)) {
    throw new ApiError(422, "STATIC_EXPORT_MATRIX", "Static stickers only accept PNG and single-frame PNG system renditions");
  }
  if (revision.kind === "static" && (system.mimeType !== "image/png" || (system.frameCount ?? 1) !== 1)) {
    throw new ApiError(422, "STATIC_SYSTEM_RENDITION_REQUIRED", "Static stickers require a single-frame PNG system rendition");
  }
  if (revision.kind === "animated" && (!request.gifAssetId || !request.mp4AssetId)) {
    throw new ApiError(422, "ANIMATED_EXPORTS_REQUIRED", "Animated stickers require GIF and MP4 exports");
  }
  if (revision.kind === "animated" && request.pngAssetId) {
    throw new ApiError(422, "ANIMATED_EXPORT_MATRIX", "Animated stickers do not accept a static PNG export relation");
  }
  // An animated sticker normally carries an animated system rendition, and a single-frame one is a
  // client that uploaded the wrong file — unless the client says otherwise. Some animations cannot
  // be squeezed under Apple's 500 KB ceiling at any size or frame rate the ladder can reach, and the
  // app ships their poster frame rather than refusing to export at all. The GIF and MP4 renditions
  // still carry the full motion, so nothing about the sticker is lost outside Messages.
  const systemIsStill = request.systemRenditionKind === "still";
  if (revision.kind === "animated" && !systemIsStill && (system.frameCount ?? 0) < 2) {
    throw new ApiError(422, "ANIMATED_SYSTEM_RENDITION_REQUIRED", "Animated stickers require an animated system rendition");
  }
  if (systemIsStill && (revision.kind !== "animated" || (system.frameCount ?? 1) !== 1)) {
    throw new ApiError(422, "INVALID_STILL_SYSTEM_RENDITION", "A still system rendition is only accepted as an animated sticker's single-frame fallback");
  }
  if (revision.kind === "animated" && !request.mp4Background) {
    throw new ApiError(422, "MP4_BACKGROUND_REQUIRED", "Animated exports must record the MP4 background used by the renderer");
  }
  if (revision.kind === "static" && request.mp4Background) {
    throw new ApiError(422, "MP4_BACKGROUND_NOT_ALLOWED", "Static exports do not use an MP4 background");
  }
  if (revision.kind === "animated") {
    const document = StickerDocumentSchema.parse(revision.documentJson);
    if (document.kind !== "animated") {
      throw new ApiError(422, "REVISION_KIND_MISMATCH", "Animated revision metadata must contain an animated sticker document");
    }
    const keyframeCount = document.layers.reduce((total, layer) => total
      + layer.animation.position.length
      + layer.animation.scale.length
      + layer.animation.rotation.length
      + layer.animation.opacity.length
      + layer.animation.effects.length, 0);
    if (keyframeCount === 0) {
      throw new ApiError(422, "ANIMATION_KEYFRAMES_REQUIRED", "Animated exports require at least one accepted animation keyframe");
    }
    for (const assetId of [request.gifAssetId, request.mp4AssetId, request.systemAssetId]) {
      if (!assetId) continue;
      // The still fallback has no cycle to match; it is one frame standing in for all of them.
      if (systemIsStill && assetId === request.systemAssetId) continue;
      validateAnimatedRenditionTiming(document, byId.get(assetId)!);
    }
  }

  const sourceDocument = StickerDocumentSchema.parse(revision.documentJson);
  await validateDocumentAssetReferences(db, ownerId, stickerId, sourceDocument, [
    revision.masterAssetId,
    revision.previewAssetId,
  ].filter((value): value is string => Boolean(value)));
  const publishedDocument = StickerDocumentSchema.parse(revision.kind === "animated"
    ? { ...sourceDocument, mp4Background: request.mp4Background }
    : sourceDocument);
  await db.transaction(async (tx) => {
    await tx.insert(stickerRevisions).values({
      id: publishedRevisionId,
      stickerId,
      parentRevisionId: request.revisionId,
      kind: revision.kind,
      candidateState: "accepted",
      documentJson: publishedDocument,
      masterAssetId: revision.masterAssetId,
      previewAssetId: revision.previewAssetId,
      pngAssetId: request.pngAssetId,
      gifAssetId: request.gifAssetId,
      mp4AssetId: request.mp4AssetId,
      systemAssetId: request.systemAssetId,
      createdAt: new Date(),
      decidedAt: new Date(),
    });
    const published = await tx.update(stickers).set({
      activeRevisionId: publishedRevisionId,
      status: "published",
      updatedAt: new Date(),
    }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
      eq(stickers.activeRevisionId, request.revisionId),
      ne(stickers.status, "deleting"),
    )).returning({ id: stickers.id });
    if (published.length === 0) {
      throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision changed before exports could be published");
    }
  });
  return { stickerId, revisionId: publishedRevisionId, sourceRevisionId: request.revisionId, status: "published" as const };
}
