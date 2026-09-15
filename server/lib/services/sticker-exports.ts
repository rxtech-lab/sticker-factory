// Binding rendered exports and messenger renditions onto a published revision.

import { and, eq, ne } from "drizzle-orm";
import type { MessengerRenditionsRequest, PublishExportsRequest } from "@/lib/contracts/api";
import { ATTACHMENT_RENDITION_DIMENSIONS } from "@/lib/contracts/api";
import { countKeyframes } from "@/lib/animation/compile";
import { preparePlaybackBundle } from "./playback";
import { StickerDocumentSchema, resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getReadyOwnedAssets } from "@/lib/services/assets";
import { validateAnimatedRenditionTiming, validateDocumentAssetReferences } from "./sticker-documents";
import { assertOwnedSticker, selectStickerSummaries, serializeStickerSummary } from "./sticker-summaries";

export async function bindExports(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PublishExportsRequest,
  publishedRevisionId = crypto.randomUUID(),
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const existingPublished = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).then(firstRow);
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
  )).then(firstRow);
  if (!revision) throw new ApiError(409, "REVISION_NOT_ACCEPTED", "The revision must be accepted before publishing");
  const ids = [
    request.pngAssetId,
    request.apngAssetId,
    request.mp4AssetId,
    request.systemAssetId,
    request.attachmentMediumAssetId,
    request.attachmentSmallAssetId,
    request.webpAssetId,
  ].filter((value): value is string => Boolean(value));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "An export belongs to another sticker");
  }
  const system = byId.get(request.systemAssetId)!;
  if (system.kind !== "system" || (system.byteSize ?? Infinity) >= 500_000) {
    throw new ApiError(422, "INVALID_SYSTEM_STICKER", "A verified system rendition below 500 KB is required");
  }
  // Only `apng` is accepted for a *new* publish. Revisions that already point at a `gif` asset keep
  // resolving through the same column — see `0009_apng_sharing_rendition.sql` — but nothing writes
  // one any more, so admitting the old kind here would only let a stale client publish a container
  // the rest of this file no longer describes.
  if (request.apngAssetId && byId.get(request.apngAssetId)?.kind !== "apng") {
    throw new ApiError(422, "INVALID_APNG_EXPORT", "Sharing APNG export asset is invalid");
  }
  if (request.mp4AssetId && byId.get(request.mp4AssetId)?.kind !== "mp4") throw new ApiError(422, "INVALID_MP4_EXPORT", "MP4 export asset is invalid");
  if (request.pngAssetId && byId.get(request.pngAssetId)?.kind !== "master") throw new ApiError(422, "INVALID_PNG_EXPORT", "PNG export asset is invalid");
  // The two smaller sends. `validateImageForKind` already proved each one is a transparent square
  // PNG at 408 or 300; what it could not know is *which* column it was headed for, so the pairing
  // is checked here. Getting them the wrong way round would silently hand someone Small when they
  // asked for Medium.
  for (const [field, assetId] of [
    ["attachmentMediumAssetId", request.attachmentMediumAssetId],
    ["attachmentSmallAssetId", request.attachmentSmallAssetId],
  ] as const) {
    if (!assetId) continue;
    const asset = byId.get(assetId)!;
    if (asset.kind !== "attachment") {
      throw new ApiError(422, "INVALID_ATTACHMENT_EXPORT", `${field} must reference an attachment rendition`);
    }
    const expected = field === "attachmentMediumAssetId"
      ? ATTACHMENT_RENDITION_DIMENSIONS.medium
      : ATTACHMENT_RENDITION_DIMENSIONS.small;
    if (asset.width !== expected) {
      throw new ApiError(422, "INVALID_ATTACHMENT_SIZE", `${field} must be ${expected} pixels wide`);
    }
    // An attachment rendition is a copy of the sharing rendition, so it moves exactly when the
    // sticker does. A still one under an animated sticker is the wrong file, and an animated one
    // under a static sticker could not have been rendered from that document at all.
    if ((revision.kind === "animated") !== ((asset.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "ATTACHMENT_RENDITION_MISMATCH",
        `${field} must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  // Optional by construction — iOS has no system WebP encoder, so a client that cannot link one
  // publishes without this and its `.image` sends keep resolving to the APNG. What is checked is
  // that a WebP which *did* arrive is the right file: the kind it claims, and moving (or not) with
  // the sticker exactly as the attachment renditions must.
  if (request.webpAssetId) {
    const webp = byId.get(request.webpAssetId)!;
    if (webp.kind !== "webp") {
      throw new ApiError(422, "INVALID_WEBP_EXPORT", "webpAssetId must reference a WebP rendition");
    }
    if ((revision.kind === "animated") !== ((webp.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "WEBP_RENDITION_MISMATCH",
        `webpAssetId must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  if (revision.kind === "static" && !request.pngAssetId) throw new ApiError(422, "PNG_EXPORT_REQUIRED", "Static stickers require a rendered PNG export");
  if (revision.kind === "static" && (request.apngAssetId || request.mp4AssetId)) {
    throw new ApiError(422, "STATIC_EXPORT_MATRIX", "Static stickers only accept PNG and single-frame PNG system renditions");
  }
  if (revision.kind === "static" && (system.mimeType !== "image/png" || (system.frameCount ?? 1) !== 1)) {
    throw new ApiError(422, "STATIC_SYSTEM_RENDITION_REQUIRED", "Static stickers require a single-frame PNG system rendition");
  }
  // The MP4 is optional: an export that is only ever going to be a sticker has no video to publish,
  // and encoding one anyway is the slowest step in a publish. The sharing APNG is not — it is what
  // the library, the share sheet and every non-Messages surface show for an animated sticker.
  if (revision.kind === "animated" && !request.apngAssetId) {
    throw new ApiError(422, "ANIMATED_EXPORTS_REQUIRED", "Animated stickers require a sharing APNG export");
  }
  if (revision.kind === "animated" && request.pngAssetId) {
    throw new ApiError(422, "ANIMATED_EXPORT_MATRIX", "Animated stickers do not accept a static PNG export relation");
  }
  // An animated sticker normally carries an animated system rendition, and a single-frame one is a
  // client that uploaded the wrong file — unless the client says otherwise. Some animations cannot
  // be squeezed under Apple's 500 KB ceiling at any size or frame rate the ladder can reach, and the
  // app ships their poster frame rather than refusing to export at all. The sharing APNG and MP4
  // renditions still carry the full motion, so nothing about the sticker is lost outside Messages.
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
    const document = resolveStickerConfiguration(StickerDocumentSchema.parse(revision.documentJson));
    if (document.kind !== "animated") {
      throw new ApiError(422, "REVISION_KIND_MISMATCH", "Animated revision metadata must contain an animated sticker document");
    }
    // Counted through the shared helper rather than by hand: this sum used to omit `trim`, which
    // rejected a perfectly good draw-on-only sticker here with a confusing 422.
    const keyframeCount = document.layers.reduce((total, layer) => total + countKeyframes(layer.animation), 0);
    const carriesFrames = document.layers.some((layer) => (
      ((layer.type === "sequence" || layer.type === "video") && layer.frameCount > 1)
      || (layer.type === "sprite" && layer.clips.some((clip) => clip.frames.length > 1))
    ));
    if (keyframeCount === 0 && !revision.documentJson.configuration && !carriesFrames) {
      throw new ApiError(422, "ANIMATION_KEYFRAMES_REQUIRED", "Animated exports require at least one accepted animation keyframe");
    }
    for (const assetId of [
      request.apngAssetId,
      request.mp4AssetId,
      request.systemAssetId,
      // Held to the document's own grid exactly like the sharing rendition they are copies of.
      // Nothing here is under the 500 KB ceiling, so unlike the system sticker they never traded
      // frame rate away and a mismatch really is a bad export.
      request.attachmentMediumAssetId,
      request.attachmentSmallAssetId,
      // WebP preserves the cycle duration but may merge repeated frames.
      request.webpAssetId,
    ]) {
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
  const playbackJson = await preparePlaybackBundle(db, ownerId, stickerId, request.revisionId, publishedDocument, request.playbackDocument);
  await db.transaction(async (tx) => {
    await tx.insert(stickerRevisions).values({
      id: publishedRevisionId,
      stickerId,
      parentRevisionId: request.revisionId,
      kind: revision.kind,
      candidateState: "accepted",
      documentJson: publishedDocument,
      playbackJson,
      masterAssetId: revision.masterAssetId,
      previewAssetId: revision.previewAssetId,
      pngAssetId: request.pngAssetId,
      apngAssetId: request.apngAssetId,
      mp4AssetId: request.mp4AssetId,
      systemAssetId: request.systemAssetId,
      attachmentMediumAssetId: request.attachmentMediumAssetId,
      attachmentSmallAssetId: request.attachmentSmallAssetId,
      webpAssetId: request.webpAssetId,
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

/**
 * Attaches the WhatsApp and Telegram renditions to a sticker's already-published revision.
 *
 * Deliberately *not* part of `bindExports`. That function mints a new published revision out of an
 * accepted candidate and charges an export job for it; these files arrive much later, when an
 * already-published sticker is put into a pack, and there is nothing new to publish — only two
 * empty columns to fill on the revision that is already active.
 *
 * Which makes this the one place in this file that mutates a published revision in place. It is
 * safe because of what it is allowed to do: it only ever writes these two columns, they take no
 * part in the preview-resolution chain, and the `activeRevisionId` guard in both statements means a
 * device edit that lands first wins — the bind then fails rather than stapling renditions onto
 * artwork that has already moved on. Anyone extending this to a third column should re-read that
 * sentence first.
 *
 * Every field is optional and independent. Artwork that fits WhatsApp's 500 KB animated ceiling
 * regularly misses Telegram's 256 KB one, and binding the rendition that worked is strictly better
 * than refusing both — a pack that can go to one messenger is not a failed pack.
 */
export async function bindMessengerRenditions(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: MessengerRenditionsRequest,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  if (sticker.status !== "published") {
    throw new ApiError(409, "STICKER_NOT_PUBLISHED", "Messenger renditions belong to a published sticker");
  }
  if (sticker.activeRevisionId !== request.revisionId) {
    throw new ApiError(409, "REVISION_NOT_ACTIVE", "Messenger renditions may only be bound to the active revision");
  }
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (!revision) throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision could not be read");

  const ids = [request.whatsappAssetId, request.telegramAssetId].filter((value): value is string => Boolean(value));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "A messenger rendition belongs to another sticker");
  }

  // `completeUpload` already proved each file is a transparent 512 px square inside its messenger's
  // byte ceiling. What it could not know is which *sticker* it was headed for, so the one thing left
  // is that the rendition moves with this one: a still file under an animated sticker would be
  // handed to a pack the messenger has been told is animated, and rejected on arrival.
  const whatsapp = request.whatsappAssetId ? byId.get(request.whatsappAssetId)! : undefined;
  if (whatsapp) {
    if (whatsapp.kind !== "messenger_whatsapp") {
      throw new ApiError(422, "INVALID_WHATSAPP_RENDITION", "whatsappAssetId must reference a WhatsApp rendition");
    }
    if ((revision.kind === "animated") !== ((whatsapp.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "WHATSAPP_RENDITION_MISMATCH",
        `whatsappAssetId must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  const telegram = request.telegramAssetId ? byId.get(request.telegramAssetId)! : undefined;
  if (telegram) {
    if (telegram.kind !== "messenger_telegram") {
      throw new ApiError(422, "INVALID_TELEGRAM_RENDITION", "telegramAssetId must reference a Telegram rendition");
    }
    // Telegram is the one destination where the container itself is the discriminator: a static
    // sticker goes as a still PNG and an animated one as a VP9 WebM. `frameCount` cannot arbitrate
    // — a WebM never reports one, because counting its frames means walking every cluster block —
    // so the mime type is what the two kinds are told apart by, and it is exact.
    const expected = revision.kind === "animated" ? "video/webm" : "image/png";
    if (telegram.mimeType !== expected) {
      throw new ApiError(
        422,
        "TELEGRAM_RENDITION_MISMATCH",
        `telegramAssetId must be ${expected} to match ${revision.kind === "animated" ? "an animated" : "a static"} sticker`,
      );
    }
  }

  const now = new Date();
  await db.transaction(async (tx) => {
    // Only the fields that arrived are written. An emoji-only call must not blank the renditions,
    // and a rendition-only call must not blank the emoji.
    const revisionPatch: Partial<typeof stickerRevisions.$inferInsert> = {};
    if (request.whatsappAssetId) revisionPatch.whatsappAssetId = request.whatsappAssetId;
    if (request.telegramAssetId) revisionPatch.telegramAssetId = request.telegramAssetId;
    if (Object.keys(revisionPatch).length > 0) {
      await tx.update(stickerRevisions).set(revisionPatch).where(and(
        eq(stickerRevisions.id, request.revisionId),
        eq(stickerRevisions.stickerId, stickerId),
      ));
    }
    // The emoji rides along on the sticker rather than the revision, so this is a second statement
    // — and the one that carries the `activeRevisionId` guard for the whole call. A racing device
    // edit moves the active revision, this matches nothing, and the bind is refused.
    const touched = await tx.update(stickers).set({
      ...(request.emoji ? { messengerEmoji: request.emoji } : {}),
      updatedAt: now,
    }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
      eq(stickers.activeRevisionId, request.revisionId),
      ne(stickers.status, "deleting"),
    )).returning({ id: stickers.id });
    if (touched.length === 0) {
      throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision changed before the renditions could be bound");
    }
  });

  // The whole summary, not an acknowledgement: the client just learned this sticker is sendable and
  // would otherwise have to re-list the pack to find out.
  const row = await selectStickerSummaries(db).where(eq(stickers.id, stickerId)).then(firstRow);
  if (!row) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  return serializeStickerSummary(row);
}
