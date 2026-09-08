// What a sticker document is allowed to say: which assets it may reference, how long an
// animated rendition may run, and whether a revision can serve as an animation base.

import { and, eq } from "drizzle-orm";
import type { PostChatMessageRequest } from "@/lib/contracts/api";
import { EXPORT_LOOP_HOLD_SECONDS, layerImageAssetIds, layerVideoAssetIds, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getReadyOwnedAssets } from "@/lib/services/assets";
import { AI_REFERENCE_MIME_TYPES } from "./sticker-summaries";

export function intentToJobKind(intent: PostChatMessageRequest["intent"]) {
  if (intent === "generate") return "image" as const;
  if (intent === "animate") return "animation" as const;
  if (intent === "chat") return "chat" as const;
  return "edit" as const;
}

/**
 * The MP4 is deliberately not required here. It is the one rendition nothing on the platform reads:
 * Messages carries the system sticker, the library and share sheet carry the sharing APNG, and the
 * MP4 exists only for somewhere else that plays video. It is also the slowest thing the app renders,
 * so a publish that was never going to share a video does not encode one — see
 * `StickerExportSelection`.
 */
export function revisionHasPublishedExports(revision: typeof stickerRevisions.$inferSelect): boolean {
  return Boolean(revision.systemAssetId && (revision.kind === "static"
    ? revision.pngAssetId
    // Either container counts. A sticker published before the switch is no less published for
    // holding a GIF, and demoting it to a draft is what reading only the new column would do.
    : revision.apngAssetId ?? revision.gifAssetId));
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
  const holdSeconds = exportHoldSeconds(document.loop);
  const expectedDuration = cycleSeconds + holdSeconds;

  // libwebp merges identical adjacent frames and adds their delays. Video sampled above its
  // source cadence commonly produces these duplicates, so encoded frame count is not render FPS.
  // Keep the original grid's duration tolerance; using the merged FPS would allow seconds of drift.
  if (rendition.kind === "webp") {
    if (rendition.frameCount > Math.ceil(cycleSeconds * document.fps) + 1) {
      throw new ApiError(422, "EXPORT_FRAME_COUNT_MISMATCH", "Animated rendition frame count does not match the accepted document cycle");
    }
    if (Math.abs(rendition.durationSeconds - expectedDuration) > 1 / document.fps + 0.01) {
      throw new ApiError(422, "EXPORT_DURATION_MISMATCH", "Animated rendition duration does not match the accepted document cycle and loop hold");
    }
    return;
  }

  // How the hold is spelled depends on what the container can say. GIF and APNG carry a delay per
  // frame, so it rides on the last one and the frame grid still spans exactly the motion cycle. An
  // H.264 track has no such field: AVAssetWriter re-derives every sample's duration from the
  // spacing of the next one, so a final sample asked to last a hold longer is written at the
  // cadence like any other and the file measures exactly the cycle. The only hold an MP4 can state
  // is a repeated frame — see `holdFrameCount` in `StickerGeniOS/Rendering/StickerExporter.swift` —
  // so its grid spans the whole export rather than the cycle.
  const holdFrames = rendition.kind === "mp4" ? Math.round(holdSeconds * document.fps) : 0;

  // Inspection reports fps as frameCount/durationSeconds, which a hold the frames do not cover
  // drags below the grid they were rendered on — recover the grid before comparing to it.
  const gridFps = rendition.frameCount / (holdFrames > 0 ? expectedDuration : cycleSeconds);

  // The sharing apng and the mp4 are rendered at the document's own fps. The system rendition walks a quality ladder
  // to fit under 500 KB, so it is a range rather than a value. The bottom of that ladder is 4 fps —
  // `SystemStickerPreset.adaptive` in `StickerGeniOS/Rendering/StickerExporter.swift` — because a
  // long cycle of dense art that cannot fit at 8 is better shipped choppy than shipped as a still.
  const fpsMatches = rendition.kind === "system"
    ? gridFps >= Math.min(document.fps, 4) - 0.5 && gridFps <= document.fps + 0.75
    : Math.abs(gridFps - document.fps) <= 0.75;
  if (!fpsMatches) throw new ApiError(422, "EXPORT_FPS_MISMATCH", "Animated rendition FPS does not match the accepted document");

  // Only the ladder renditions get to pick their own grid, so everything else has an exact count to
  // hit. This is what catches a frame dropped or duplicated at the ends of the cycle.
  const expectedFrames = Math.ceil(cycleSeconds * document.fps) + holdFrames;
  if (rendition.kind !== "system" && Math.abs(rendition.frameCount - expectedFrames) > 1.01) {
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
  const sequenceLayers = document.layers.filter(
    (layer): layer is Extract<typeof layer, { type: "sequence" }> => layer.type === "sequence",
  );
  const videoLayers = document.layers.filter(
    (layer): layer is Extract<typeof layer, { type: "video" }> => layer.type === "video",
  );
  const ids = [...new Set([
    ...additionalAssetIds,
    ...document.layers.flatMap(layerImageAssetIds),
    // The clip: `layerImageAssetIds` reports a video layer's poster, since that is what the server
    // draws, and the MP4 the client plays has to clear the same ownership bar.
    ...document.layers.flatMap(layerVideoAssetIds),
    // The poster is what a pre-v3 client is served in place of the footage, so it has to clear the
    // same ownership bar as everything else the document names.
    ...sequenceLayers.flatMap((layer) => (layer.posterAssetId ? [layer.posterAssetId] : [])),
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
  for (const layer of sequenceLayers) {
    const atlas = byId.get(layer.assetId)!;
    if (atlas.kind !== "sequence" || atlas.mimeType !== "image/png" || !atlas.hasAlpha) {
      throw new ApiError(422, "INVALID_SEQUENCE_ASSET", "Capture layers must reference a validated transparent frame atlas");
    }
    // The layer and the asset row each carry the frame grid, and the renderer trusts the layer while
    // the exporter's timing checks trust neither. If they disagree, the sticker plays footage that
    // is not the footage that was uploaded — so this is a mismatch worth refusing, not reconciling.
    if (
      atlas.frameCount !== layer.frameCount
      || atlas.fps !== layer.frameRate
      || atlas.sequenceColumns !== layer.columns
      || atlas.sequenceRows !== layer.rows
    ) {
      throw new ApiError(
        422,
        "SEQUENCE_METADATA_MISMATCH",
        "A capture layer's grid, frame count, and rate must match the uploaded atlas",
      );
    }
    if (layer.posterAssetId) {
      const poster = byId.get(layer.posterAssetId)!;
      if (poster.mimeType !== "image/png" || !poster.hasAlpha) {
        throw new ApiError(422, "INVALID_SEQUENCE_POSTER", "A capture layer's still frame must be a transparent PNG");
      }
    }
  }
  for (const layer of videoLayers) {
    const clip = byId.get(layer.assetId)!;
    if (clip.kind !== "video" || clip.mimeType !== "video/mp4" || !clip.width || clip.width !== clip.height) {
      throw new ApiError(422, "INVALID_VIDEO_ASSET", "Video layers must reference a validated square generated clip");
    }
    // Same reasoning as the capture check above: the renderer trusts the layer's timing, and the
    // container is the one thing that knows the truth.
    if (clip.frameCount !== layer.frameCount || clip.fps !== layer.frameRate) {
      throw new ApiError(
        422,
        "VIDEO_METADATA_MISMATCH",
        "A video layer's frame count and rate must match the stored clip",
      );
    }
    const poster = byId.get(layer.posterAssetId)!;
    if (poster.mimeType !== "image/png" || !poster.hasAlpha) {
      throw new ApiError(422, "INVALID_VIDEO_POSTER", "A video layer's poster must be a transparent PNG");
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
  )).then(firstRow);
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
    )).then(firstRow);
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
