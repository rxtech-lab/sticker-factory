import { lastPublishedPlayback } from "./playback";
import { createHash } from "node:crypto";
import { and, eq, inArray, isNull, lt, or, sql } from "drizzle-orm";
import sharp from "sharp";
import {
  ATTACHMENT_RENDITION_DIMENSIONS,
  MESSENGER_RENDITION_DIMENSION,
  TELEGRAM_ANIMATED_BYTE_LIMIT,
  TELEGRAM_MAX_SECONDS,
  TELEGRAM_STATIC_BYTE_LIMIT,
  WHATSAPP_ANIMATED_BYTE_LIMIT,
  WHATSAPP_MAX_SECONDS,
  WHATSAPP_STATIC_BYTE_LIMIT,
  type CreateUploadRequest,
} from "@/lib/contracts/api";
import { MAX_RENDITION_SECONDS, RENDITION_TIMING_EPSILON_SECONDS, SHARING_APNG_DIMENSIONS, type StickerDocument } from "@/lib/contracts/sticker";
import { compositeSpriteFrame } from "@/lib/render/sprite-registration";
import { firstRow, type Database } from "@/lib/db/client";
import { previewAssetIdSql } from "@/lib/db/columns";
import { assets, stickerPackItems, stickerPacks, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  getObjectStore,
  inspectImage,
  inspectMp4,
  inspectWebM,
  objectKey,
  type ImageInspection,
} from "@/lib/storage/r2";

const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/webp", "image/gif"]);

/**
 * A stable asset id for the output named `slot` of `seed` (a generation job id) — a part index,
 * or a name like `"concept"` for a job's single non-part image.
 *
 * Workflow steps replay, so a composed turn cannot mint random ids per part — a retry would
 * orphan the previous R2 objects and produce a second set of asset rows. Deriving from
 * (jobId, slot) makes the whole turn idempotent the same way `assetId = job.id` does for the
 * single-image path.
 *
 * The result is shaped as a version-4 UUID because that is the intersection of what both ends
 * accept: zod's `z.string().uuid()` checks the version nibble, and Swift's document validation
 * requires `UUID(uuidString:)` to parse.
 */
export function derivedAssetId(seed: string, slot: number | string): string {
  const bytes = Buffer.from(createHash("sha256").update(`${seed}:${slot}`).digest().subarray(0, 16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

/**
 * Fills in the poster frame every sequence layer needs before the document can be stored.
 *
 * A poster is tile 0 of the atlas, cut out as its own PNG. It is what `downcastForClient` serves to
 * a client too old to decode a sequence layer, so deriving it is not optional bookkeeping: without
 * one, such a client is handed a document with the layer *missing* rather than stilled.
 *
 * The id is derived from the atlas rather than from the job, so the same footage carried across a
 * dozen revisions produces one poster and pays for the extract once. That also makes this safe to
 * call on a workflow replay: the second run finds the row already there and does nothing.
 *
 * Returns the document with `posterAssetId` populated. Never throws for a poster that cannot be
 * made — a sticker whose footage the *current* client can play should not fail to save because an
 * older client's fallback could not be produced. `downcastForClient` drops a posterless layer.
 */
export async function ensureSequencePosters(
  db: Database,
  ownerId: string,
  stickerId: string,
  document: StickerDocument,
): Promise<StickerDocument> {
  const pending = document.layers.filter(
    (layer): layer is Extract<typeof layer, { type: "sequence" }> => layer.type === "sequence" && !layer.posterAssetId,
  );
  if (pending.length === 0) return document;

  const posters = new Map<string, string>();
  for (const layer of pending) {
    if (posters.has(layer.id)) continue;
    const posterId = await ensureAtlasPoster(db, ownerId, stickerId, layer);
    if (posterId) posters.set(layer.id, posterId);
  }
  if (posters.size === 0) return document;

  return {
    ...document,
    layers: document.layers.map((layer) => (
      layer.type === "sequence" && posters.has(layer.id)
        ? { ...layer, posterAssetId: posters.get(layer.id)! }
        : layer
    )),
  } as StickerDocument;
}

/**
 * Tile 0 of a frame atlas, stored as its own PNG asset. Returns its id, or nothing if it could not
 * be made.
 *
 * Shared by the poster path above and by plan cards, which show it as the preview for a capture-led
 * plan. Such a plan renders no generated concept — the footage *is* the reference — so without this
 * the card had nothing to show but its layout boxes, and the user was asked to approve a design of
 * their own face sight unseen.
 *
 * Idempotent: the id is derived from the atlas, and an existing ready row short-circuits, so a
 * revision that keeps the same footage and a workflow replay both cost one lookup.
 */
export async function ensureAtlasPoster(
  db: Database,
  ownerId: string,
  stickerId: string,
  atlas: { assetId: string; columns: number; rows: number },
): Promise<string | undefined> {
  const posterId = derivedAssetId(atlas.assetId, "poster");
  try {
    const existing = await db.select({ id: assets.id, state: assets.state }).from(assets)
      .where(and(eq(assets.id, posterId), eq(assets.ownerId, ownerId))).then(firstRow);
    if (existing?.state === "ready") return posterId;

    const source = await db.select().from(assets)
      .where(and(eq(assets.id, atlas.assetId), eq(assets.ownerId, ownerId), eq(assets.state, "ready"))).then(firstRow);
    if (!source?.width || !source.height) return undefined;
    const object = await getObjectStore().get(source.r2Key);
    // Integer division on the pixel dimensions, matching how the renderer slices tiles, so the
    // poster is exactly the frame a playing client shows at t=0 rather than an off-by-a-pixel crop.
    const bytes = await sharp(Buffer.from(object.bytes))
      .extract({
        left: 0,
        top: 0,
        width: Math.floor(source.width / atlas.columns),
        height: Math.floor(source.height / atlas.rows),
      })
      .png()
      .toBuffer();
    const inspection = await inspectImage(bytes);
    const r2Key = objectKey(ownerId, posterId, "image/png");
    await getObjectStore().put(r2Key, { bytes, contentType: "image/png", metadata: { sha256: inspection.sha256 } });
    await db.insert(assets).values({
      id: posterId,
      ownerId,
      stickerId,
      // `master` rather than a kind of its own: it is a finished still of the sticker's artwork,
      // which is exactly what an image layer is allowed to reference.
      kind: "master",
      state: "ready",
      r2Key,
      mimeType: "image/png",
      byteSize: inspection.byteSize,
      width: inspection.width,
      height: inspection.height,
      sha256: inspection.sha256,
      hasAlpha: inspection.hasTransparentPixels,
      originalFilename: "capture-poster.png",
      createdAt: new Date(),
      readyAt: new Date(),
    }).onConflictDoNothing();
    return posterId;
  } catch {
    // Deliberately swallowed: a poster is a nicety on both call sites — an older client's fallback
    // and a card's thumbnail — and neither is worth failing a save or a planning turn over.
    return undefined;
  }
}

/**
 * The still a sprite layer is served as wherever it cannot be composited: its default clip's first
 * frame with its default face drawn in, fitted into the same 1024x1024 transparent square every
 * other image asset is.
 *
 * Unlike a capture's poster this one is required — the layer schema says so — so a failure throws
 * rather than returning nothing. Idempotent on the id, which is derived from the sheets and the
 * face, so a replayed build costs one lookup.
 */
export async function ensureSpritePoster(
  db: Database,
  ownerId: string,
  stickerId: string,
  sprite: {
    clip: { assetId: string; columns: number; rows: number; frames: readonly { faceX: number; faceY: number; faceSize: number }[]; faceCompositing?: "overlay" | "masked"; faceMaskAssetId?: string };
    expressions: { assetId: string };
    tile: { id: string; x: number; y: number; width: number; height: number };
  },
): Promise<string> {
  const posterId = derivedAssetId(
    sprite.clip.assetId,
    `sprite-poster:${sprite.expressions.assetId}:${sprite.tile.id}:${sprite.clip.faceMaskAssetId ?? "overlay"}`,
  );
  const existing = await db.select({ id: assets.id, state: assets.state }).from(assets)
    .where(and(eq(assets.id, posterId), eq(assets.ownerId, ownerId))).then(firstRow);
  if (existing?.state === "ready") return posterId;

  const ids = [sprite.clip.assetId, sprite.expressions.assetId, sprite.clip.faceMaskAssetId].filter((id): id is string => Boolean(id));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((row) => [row.id, row]));
  const atlas = byId.get(sprite.clip.assetId)!;
  const sheet = byId.get(sprite.expressions.assetId)!;
  const mask = sprite.clip.faceMaskAssetId ? byId.get(sprite.clip.faceMaskAssetId) : undefined;
  const store = getObjectStore();
  const frame = await compositeSpriteFrame({
    atlas: (await store.get(atlas.r2Key)).bytes,
    clip: sprite.clip,
    index: 0,
    sheet: (await store.get(sheet.r2Key)).bytes,
    tile: sprite.tile,
    maskAtlas: mask ? (await store.get(mask.r2Key)).bytes : undefined,
  });
  const bytes = await sharp(Buffer.from(frame))
    .resize(1024, 1024, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  const inspection = await inspectImage(bytes);
  const r2Key = objectKey(ownerId, posterId, "image/png");
  await store.put(r2Key, { bytes, contentType: "image/png", metadata: { sha256: inspection.sha256 } });
  await db.insert(assets).values({
    id: posterId,
    ownerId,
    stickerId,
    kind: "master",
    state: "ready",
    r2Key,
    mimeType: "image/png",
    byteSize: inspection.byteSize,
    width: inspection.width,
    height: inspection.height,
    sha256: inspection.sha256,
    hasAlpha: inspection.hasTransparentPixels,
    originalFilename: "sprite-poster.png",
    createdAt: new Date(),
    readyAt: new Date(),
  }).onConflictDoUpdate({ target: assets.id, set: { state: "ready", byteSize: inspection.byteSize, sha256: inspection.sha256, width: inspection.width, height: inspection.height, hasAlpha: inspection.hasTransparentPixels, readyAt: new Date() } });
  return posterId;
}

async function assertOwnedSticker(db: Database, ownerId: string, stickerId?: string): Promise<void> {
  if (!stickerId) return;
  const sticker = await db.select({ id: stickers.id, deletedAt: stickers.deletedAt }).from(stickers)
    .where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId))).then(firstRow);
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
}

export async function createUpload(db: Database, ownerId: string, request: CreateUploadRequest) {
  await assertOwnedSticker(db, ownerId, request.stickerId);
  const id = crypto.randomUUID();
  const r2Key = objectKey(ownerId, id, request.mimeType);
  await db.insert(assets).values({
    id,
    ownerId,
    stickerId: request.stickerId,
    kind: request.kind,
    state: "pending",
    r2Key,
    mimeType: request.mimeType,
    byteSize: request.byteSize,
    sha256: request.sha256,
    originalFilename: request.filename,
    // A frame atlas is a single still, so inspecting the object can never recover how it is packed.
    // The client's declaration is the only source there is, and it is written here — before the
    // bytes exist — so `completeUpload` has something to preserve rather than something to derive.
    frameCount: request.sequence?.frameCount,
    fps: request.sequence?.frameRate,
    durationSeconds: request.sequence && request.sequence.frameCount / request.sequence.frameRate,
    sequenceColumns: request.sequence?.columns,
    sequenceRows: request.sequence?.rows,
    createdAt: new Date(),
  });
  const upload = await getObjectStore().signedPut(r2Key, request.mimeType, request.byteSize);
  return {
    asset: { id, kind: request.kind, state: "pending", mimeType: request.mimeType, byteSize: request.byteSize },
    upload: { url: upload.url, expiresAt: upload.expiresAt.toISOString(), headers: upload.headers },
  };
}

/**
 * Held to by everything that mints an asset row, uploads and server-rendered renditions
 * alike — `lib/services/quick-publish.ts` runs its own output through this so a rendition the
 * server drew answers to exactly the standard one the app uploaded does.
 */
export function validateImageForKind(
  asset: typeof assets.$inferSelect,
  inspection: ImageInspection,
): void {
  if (inspection.mimeType !== asset.mimeType) {
    throw new ApiError(422, "MIME_MISMATCH", "The uploaded image does not match its declared MIME type");
  }
  if (inspection.width < 64 || inspection.height < 64 || inspection.width > 4096 || inspection.height > 4096) {
    throw new ApiError(422, "INVALID_DIMENSIONS", "Images must be between 64 and 4096 pixels per side");
  }
  if (asset.kind === "mask") {
    if (!inspection.hasAlpha || !inspection.hasTransparentPixels || !inspection.hasNonTransparentPixels) {
      throw new ApiError(422, "MASK_REQUIRES_ALPHA", "Masks must contain both transparent and painted alpha pixels");
    }
  }
  if ((asset.kind === "reference" || asset.kind === "chat_attachment") && inspection.frameCount !== 1) {
    throw new ApiError(422, "ANIMATED_REFERENCE_NOT_SUPPORTED", "AI reference uploads must be single-frame images");
  }
  if (asset.kind === "sequence") {
    // `frameCount !== 1` is the *correct* assertion here, counterintuitive as it reads. The atlas
    // is a sprite sheet: a single still image whose frames are laid out in a grid. An animated file
    // arriving under this kind means the client packed it wrong, and would play as one frame.
    if (inspection.mimeType !== "image/png" || inspection.frameCount !== 1) {
      throw new ApiError(422, "INVALID_SEQUENCE_ATLAS", "A frame atlas must be a single-frame PNG");
    }
    if (!inspection.hasAlpha || !inspection.hasTransparentPixels || !inspection.hasNonTransparentPixels) {
      throw new ApiError(
        422,
        "SEQUENCE_REQUIRES_ALPHA",
        "A frame atlas must contain both transparent and painted pixels — the subject is cut out of its background",
      );
    }
  }
  if (asset.kind === "master") {
    if (inspection.mimeType !== "image/png" || inspection.width !== 1024 || inspection.height !== 1024 || inspection.frameCount !== 1) {
      throw new ApiError(422, "INVALID_MASTER", "Static masters must be 1024x1024 PNG files");
    }
    if (!inspection.hasTransparentPixels) {
      throw new ApiError(422, "MASTER_REQUIRES_TRANSPARENCY", "Static masters must contain transparent pixels");
    }
  }
  if (asset.kind === "system") {
    if (inspection.mimeType !== "image/png" && inspection.mimeType !== "image/gif") {
      throw new ApiError(422, "INVALID_SYSTEM_STICKER", "System stickers must be PNG, APNG, or GIF files");
    }
    if (inspection.byteSize >= 500_000) {
      throw new ApiError(422, "SYSTEM_STICKER_TOO_LARGE", "System stickers must be below 500 KB");
    }
    if (inspection.width !== inspection.height || !new Set([300, 408, 618]).has(inspection.width)) {
      throw new ApiError(422, "INVALID_SYSTEM_STICKER_SIZE", "System stickers must be square at 300, 408, or 618 pixels");
    }
    if (!inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(422, "SYSTEM_STICKER_REQUIRES_TRANSPARENCY", "System sticker renditions must contain transparent pixels");
    }
    if (inspection.mimeType === "image/gif" && inspection.frameCount < 2) {
      throw new ApiError(422, "INVALID_SYSTEM_ANIMATION", "Animated system GIFs must contain multiple frames");
    }
    if (inspection.frameCount > 1 && (inspection.durationSeconds < 0.5 - RENDITION_TIMING_EPSILON_SECONDS || inspection.durationSeconds > MAX_RENDITION_SECONDS + RENDITION_TIMING_EPSILON_SECONDS || inspection.fps > 30.01)) {
      throw new ApiError(422, "INVALID_SYSTEM_ANIMATION", `Animated system stickers must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
  if (asset.kind === "apng") {
    // `frameCount > 1` is what makes this an APNG rather than a still PNG: the mime type cannot
    // say, because an APNG *is* a PNG to everything that transports it. `inspectImage` reads the
    // count back off the `acTL`/`fcTL` chunks — libvips has no APNG decoder, so sharp alone would
    // report an animated sticker as a single page and this check would reject every valid export.
    //
    // The dimension is a range rather than a value for the same reason the system rendition's is:
    // the export walks `SHARING_APNG_DIMENSIONS` down until the file fits the upload ceiling. Its
    // frame grid is still exact — `validateAnimatedRenditionTiming` checks that — so pixels are all
    // this admits.
    if (inspection.mimeType !== "image/png" || inspection.width !== inspection.height
      || !SHARING_APNG_DIMENSIONS.includes(inspection.width as typeof SHARING_APNG_DIMENSIONS[number])
      || inspection.frameCount < 2 || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(
        422,
        "INVALID_APNG_EXPORT",
        `Animated sharing renditions must be animated square APNGs at ${SHARING_APNG_DIMENSIONS.join(", ")} pixels`,
      );
    }
    if (inspection.durationSeconds < 0.5 - RENDITION_TIMING_EPSILON_SECONDS || inspection.durationSeconds > MAX_RENDITION_SECONDS + RENDITION_TIMING_EPSILON_SECONDS || inspection.fps > 30.01) {
      throw new ApiError(422, "INVALID_APNG_TIMING", `Animated sharing renditions must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
  if (asset.kind === "webp") {
    // Same artwork and same pixel ladder as the sharing rendition it copies, but — unlike `apng` —
    // a single frame is admitted: a *static* sticker has a WebP too, and it is a still by
    // definition. WebP needs no `readApngTiming` equivalent to tell the two apart, because libvips
    // pages the format natively and `inspectImage` reports the real count.
    if (inspection.mimeType !== "image/webp" || inspection.width !== inspection.height
      || !SHARING_APNG_DIMENSIONS.includes(inspection.width as typeof SHARING_APNG_DIMENSIONS[number])
      || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(
        422,
        "INVALID_WEBP_EXPORT",
        `WebP sharing renditions must be transparent square WebPs at ${SHARING_APNG_DIMENSIONS.join(", ")} pixels`,
      );
    }
    if (inspection.frameCount > 1
      && (inspection.durationSeconds < 0.5 - RENDITION_TIMING_EPSILON_SECONDS || inspection.durationSeconds > MAX_RENDITION_SECONDS + RENDITION_TIMING_EPSILON_SECONDS || inspection.fps > 30.01)) {
      throw new ApiError(422, "INVALID_WEBP_TIMING", `Animated WebP renditions must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
  if (asset.kind === "attachment") {
    // Unlike `apng` this admits a single frame: a static sticker has Medium and Small renditions
    // too, and they are ordinary still PNGs. What it does not admit is a *size* other than the two
    // it is for — Large is the sharing rendition and never arrives under this kind, so a 618 or
    // 1024 px file here is a client that filled the wrong column.
    const sizes = Object.values(ATTACHMENT_RENDITION_DIMENSIONS) as number[];
    if (inspection.mimeType !== "image/png" || inspection.width !== inspection.height
      || !sizes.includes(inspection.width) || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(
        422,
        "INVALID_ATTACHMENT_EXPORT",
        `Attachment renditions must be transparent square PNGs at ${sizes.join(" or ")} pixels`,
      );
    }
    // Animated ones answer to the same timing rules as the sharing rendition they are a copy of.
    // They are rendered without the 500 KB ceiling, so — unlike the system sticker — they never
    // trade frame rate away and this bound is the document's own.
    if (inspection.frameCount > 1
      && (inspection.durationSeconds < 0.5 - RENDITION_TIMING_EPSILON_SECONDS || inspection.durationSeconds > MAX_RENDITION_SECONDS + RENDITION_TIMING_EPSILON_SECONDS || inspection.fps > 30.01)) {
      throw new ApiError(422, "INVALID_ATTACHMENT_TIMING", `Animated attachment renditions must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
  if (asset.kind === "messenger_whatsapp") {
    // 512 exactly, never a range: WhatsApp checks the dimension itself and refuses anything else,
    // which is why the client's ladder spends quality and frame rate but never pixels.
    if (inspection.mimeType !== "image/webp"
      || inspection.width !== MESSENGER_RENDITION_DIMENSION || inspection.height !== MESSENGER_RENDITION_DIMENSION
      || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(
        422,
        "INVALID_WHATSAPP_RENDITION",
        `WhatsApp renditions must be transparent ${MESSENGER_RENDITION_DIMENSION}×${MESSENGER_RENDITION_DIMENSION} WebP files`,
      );
    }
    // Two ceilings, and which one applies is the file's own business: a still is held to 100 KB and
    // an animation to 500 KB, exactly as WhatsApp holds them. `frameCount` is trustworthy here
    // because libvips pages WebP natively — unlike APNG, which needs its chunks read by hand.
    const limit = inspection.frameCount > 1 ? WHATSAPP_ANIMATED_BYTE_LIMIT : WHATSAPP_STATIC_BYTE_LIMIT;
    if (inspection.byteSize > limit) {
      throw new ApiError(422, "WHATSAPP_RENDITION_TOO_LARGE", `WhatsApp ${inspection.frameCount > 1 ? "animated" : "still"} renditions must be ${limit / 1024} KB or smaller`);
    }
    if (inspection.frameCount > 1 && inspection.durationSeconds > WHATSAPP_MAX_SECONDS + 0.01) {
      throw new ApiError(422, "INVALID_WHATSAPP_TIMING", `Animated WhatsApp renditions must be ${WHATSAPP_MAX_SECONDS} seconds or shorter`);
    }
  }
  // Only the still half of the kind lands here. An animated Telegram rendition is a WebM, which is
  // not an image at all and never reaches `inspectImage` — `completeUpload` sends it to
  // `inspectWebM` instead.
  if (asset.kind === "messenger_telegram") {
    if (inspection.mimeType !== "image/png" || inspection.frameCount !== 1
      || inspection.width !== MESSENGER_RENDITION_DIMENSION || inspection.height !== MESSENGER_RENDITION_DIMENSION
      || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(
        422,
        "INVALID_TELEGRAM_RENDITION",
        `Telegram still renditions must be transparent single-frame ${MESSENGER_RENDITION_DIMENSION}×${MESSENGER_RENDITION_DIMENSION} PNG files`,
      );
    }
    if (inspection.byteSize > TELEGRAM_STATIC_BYTE_LIMIT) {
      throw new ApiError(422, "TELEGRAM_RENDITION_TOO_LARGE", `Telegram still renditions must be ${TELEGRAM_STATIC_BYTE_LIMIT / 1024} KB or smaller`);
    }
  }
}

export async function completeUpload(db: Database, ownerId: string, assetId: string, expectedSha256?: string) {
  const asset = await db.select().from(assets)
    .where(and(eq(assets.id, assetId), eq(assets.ownerId, ownerId))).then(firstRow);
  if (!asset) throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
  if (asset.state === "ready") return serializeAsset(asset);
  if (asset.state !== "pending") throw new ApiError(409, "ASSET_NOT_PENDING", "The asset cannot be completed");
  if (asset.stickerId) await assertOwnedSticker(db, ownerId, asset.stickerId);

  const store = getObjectStore();
  const [head, object] = await Promise.all([store.head(asset.r2Key), store.get(asset.r2Key)]);
  if (head.contentType !== asset.mimeType || object.contentType !== asset.mimeType) {
    throw new ApiError(422, "MIME_MISMATCH", "The uploaded object Content-Type is invalid");
  }
  if (head.byteSize !== asset.byteSize || object.bytes.byteLength !== asset.byteSize) {
    throw new ApiError(422, "SIZE_MISMATCH", "The uploaded object size is invalid");
  }

  let inspection: ImageInspection | undefined;
  let mp4Inspection: ReturnType<typeof inspectMp4> | undefined;
  let webmInspection: ReturnType<typeof inspectWebM> | undefined;
  if (IMAGE_TYPES.has(asset.mimeType)) {
    inspection = await inspectImage(object.bytes);
    validateImageForKind(asset, inspection);
  } else if (asset.kind === "mp4" && asset.mimeType === "video/mp4") {
    mp4Inspection = inspectMp4(object.bytes);
    if (mp4Inspection.width !== 1024 || mp4Inspection.height !== 1024) {
      throw new ApiError(422, "INVALID_MP4_DIMENSIONS", "MP4 exports must be 1024x1024");
    }
  } else if (asset.kind === "messenger_telegram" && asset.mimeType === "video/webm") {
    // Telegram's animated rendition, the one file in this API that no image decoder can open.
    webmInspection = inspectWebM(object.bytes);
    if (webmInspection.width !== MESSENGER_RENDITION_DIMENSION || webmInspection.height !== MESSENGER_RENDITION_DIMENSION) {
      throw new ApiError(
        422,
        "INVALID_TELEGRAM_RENDITION",
        `Telegram video renditions must be ${MESSENGER_RENDITION_DIMENSION}×${MESSENGER_RENDITION_DIMENSION}`,
      );
    }
    if (webmInspection.byteSize > TELEGRAM_ANIMATED_BYTE_LIMIT) {
      throw new ApiError(422, "TELEGRAM_RENDITION_TOO_LARGE", `Telegram video renditions must be ${TELEGRAM_ANIMATED_BYTE_LIMIT / 1024} KB or smaller`);
    }
    // A zero here means the muxer wrote no duration, not that the clip is empty — the ceiling is
    // what Telegram enforces, so only an over-long file is refused.
    if (webmInspection.durationSeconds > TELEGRAM_MAX_SECONDS + 0.01) {
      throw new ApiError(422, "INVALID_TELEGRAM_TIMING", `Telegram video renditions must be ${TELEGRAM_MAX_SECONDS} seconds or shorter`);
    }
  } else {
    throw new ApiError(422, "UNSUPPORTED_MEDIA", "This asset kind requires an image");
  }

  const actualSha256 = inspection?.sha256 ?? mp4Inspection?.sha256 ?? webmInspection?.sha256
    ?? (await import("node:crypto")).createHash("sha256").update(object.bytes).digest("hex");
  const requiredSha = expectedSha256 ?? asset.sha256;
  if (requiredSha && requiredSha.toLowerCase() !== actualSha256) {
    throw new ApiError(422, "CHECKSUM_MISMATCH", "The uploaded object checksum is invalid");
  }

  // A frame atlas keeps the timing the client declared at `createUpload`. Every other kind reads its
  // timing back out of the file, but an atlas *is* a single still — inspection reports one frame at
  // no rate — so applying the usual rule here would overwrite a declared twelve frames with one and
  // the sequence would play frozen, with nothing anywhere reporting an error.
  const declaresOwnTiming = asset.kind === "sequence";
  const [ready] = await db.update(assets).set({
    state: "ready",
    byteSize: object.bytes.byteLength,
    width: inspection?.width ?? mp4Inspection?.width ?? webmInspection?.width,
    height: inspection?.height ?? mp4Inspection?.height ?? webmInspection?.height,
    // A WebM contributes no frame count: counting its frames means walking every cluster block, and
    // nothing reads the number. The client learns an animated Telegram rendition is animated from
    // the sticker's own `kind`, which is the same thing it used to decide to encode a video.
    frameCount: declaresOwnTiming ? asset.frameCount : inspection?.frameCount ?? mp4Inspection?.frameCount,
    durationSeconds: declaresOwnTiming
      ? asset.durationSeconds
      : inspection?.durationSeconds ?? mp4Inspection?.durationSeconds ?? webmInspection?.durationSeconds,
    fps: declaresOwnTiming ? asset.fps : inspection?.fps ?? mp4Inspection?.fps,
    sha256: actualSha256,
    hasAlpha: inspection?.hasAlpha,
    readyAt: new Date(),
  }).where(and(
    eq(assets.id, asset.id),
    eq(assets.state, "pending"),
    asset.stickerId
      ? sql`EXISTS (SELECT 1 FROM stickers s WHERE s.id = ${asset.stickerId} AND s.owner_id = ${ownerId} AND s.status != 'deleting' AND s.deleted_at IS NULL)`
      : undefined,
  )).returning();
  if (!ready) {
    await store.delete(asset.r2Key);
    throw new ApiError(409, "STICKER_DELETING", "The sticker was deleted before this upload could be completed");
  }
  return serializeAsset(ready);
}

export async function getOwnedAsset(db: Database, ownerId: string, assetId: string) {
  const asset = await db.select().from(assets)
    .where(and(eq(assets.id, assetId), eq(assets.ownerId, ownerId))).then(firstRow);
  if (!asset || asset.state === "deleted") throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
  return asset;
}

export async function getReadyOwnedAssets(db: Database, ownerId: string, assetIds: string[]) {
  if (assetIds.length === 0) return [];
  const rows = await db.select().from(assets).where(and(
    eq(assets.ownerId, ownerId),
    eq(assets.state, "ready"),
    inArray(assets.id, assetIds),
  ));
  if (rows.length !== new Set(assetIds).size) throw new ApiError(422, "INVALID_ASSET_REFERENCE", "One or more assets are missing or not ready");
  return rows;
}

/** How a requester earned the right to read an asset. */
export type AssetAudience = "owner" | "pack-member";

/**
 * The only asset kinds a marketplace pack may expose. Everything else — references, masks, the
 * MP4 sharing rendition — stays owner-only no matter how widely the sticker is published.
 */
/**
 * Note the absence of `sequence`. A frame atlas is the user's own face and body, lifted from their
 * camera roll; it is a source, not a rendition, and it must never become marketplace-visible no
 * matter what pack the sticker ends up in. The published renditions here are drawn *from* it and
 * are what a stranger is allowed to see.
 */
/**
 * `gif` sits beside `apng` because it is the sharing rendition of every animated sticker published
 * before the switch. Dropping it here would blank the artwork on those packs' browse and detail
 * pages rather than merely serving an older container.
 */
/**
 * `attachment` is here for the same reason `system` is: an installed pack's stickers have to be
 * sendable from the Messages extensions, and without it Medium and Small would silently fall back
 * to Large for every sticker the user did not create themselves.
 */
/**
 * `webp` is here for the same reason `attachment` is, and it is not optional: an installed pack's
 * stickers are sent from WinkySticker like any other, and that surface now prefers the WebP copy of
 * the sharing rendition. Leaving it owner-only would turn every `.image` send of a borrowed sticker
 * into a 404 on a rendition the listing had just offered.
 */
/**
 * The messenger renditions are here for the plainest reason of all: sending an installed pack on to
 * WhatsApp or Telegram is what installing it is *for*. Leaving them owner-only would let the pack
 * screen offer two hand-off buttons and then 404 on every sticker the moment either was pressed.
 */
const PACK_SHARED_ASSET_KINDS = [
  "system", "preview", "apng", "gif", "master", "attachment", "webp",
  "messenger_whatsapp", "messenger_telegram",
] as const;

/**
 * Whether `asset` is artwork the marketplace has already made public.
 *
 * True only when the asset is the system rendition, or the resolved preview-chain asset, of the
 * *active* revision of a *published* sticker that belongs to a pack in a publicly visible state.
 *
 * Note there is no `pack_installs` term. Browse and pack-detail pages have to render artwork to
 * people who have not installed anything, and publishing to an open marketplace is consent to
 * display. Install membership gates which *sections* a user is served, not which bytes they may
 * read. If private or invite-only packs ever ship, adding the join here is the whole change.
 */
async function isPackPublishedAsset(db: Database, asset: typeof assets.$inferSelect): Promise<boolean> {
  if (!asset.stickerId) return false;
  if (asset.state !== "ready") return false;
  if (!PACK_SHARED_ASSET_KINDS.includes(asset.kind as (typeof PACK_SHARED_ASSET_KINDS)[number])) return false;
  const match = await db.select({ one: sql<number>`1` })
    .from(stickerPackItems)
    .innerJoin(stickerPacks, eq(stickerPacks.id, stickerPackItems.packId))
    .innerJoin(stickers, eq(stickers.id, stickerPackItems.stickerId))
    .innerJoin(stickerRevisions, eq(stickerRevisions.id, stickers.activeRevisionId))
    .where(and(
      eq(stickerPackItems.stickerId, asset.stickerId),
      inArray(stickerPacks.state, ["published", "unlisted"]),
      eq(stickers.status, "published"),
      isNull(stickers.deletedAt),
      or(
        eq(stickerRevisions.systemAssetId, asset.id),
        eq(previewAssetIdSql, asset.id),
        // Deliberately outside `previewAssetIdSql`: the WebP must never *replace* the preview a
        // client resolves, only be readable beside it.
        eq(stickerRevisions.webpAssetId, asset.id),
        // Same reasoning again for the two messenger renditions: readable beside the preview, never
        // in place of it. A WebM is not artwork anything in this app can draw.
        eq(stickerRevisions.whatsappAssetId, asset.id),
        eq(stickerRevisions.telegramAssetId, asset.id),
      ),
    ))
    .limit(1)
    .then(firstRow);
  return match !== undefined;
}

/**
 * The asset the requester may read, and on what grounds.
 *
 * Ownership first; failing that, the marketplace rule in `isPackPublishedAsset`. A failure is
 * always a 404 and never a 403 — confirming that another user's asset id exists is itself a leak.
 *
 * `getOwnedAsset` stays for callers that must never widen (uploads, purges, AI inputs).
 */
export async function getReadableAsset(
  db: Database,
  requesterId: string,
  assetId: string,
): Promise<{ asset: typeof assets.$inferSelect; audience: AssetAudience }> {
  const asset = await db.select().from(assets).where(eq(assets.id, assetId)).then(firstRow);
  if (!asset || asset.state === "deleted") throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
  if (asset.ownerId === requesterId) return { asset, audience: "owner" };
  if (asset.kind === "playback" && asset.stickerId) {
    const row = await lastPublishedPlayback(db, requesterId, asset.stickerId);
    if (row.revision.playbackJson?.assetIds.includes(asset.id)) return { asset, audience: "pack-member" };
    throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
  }
  if (await isPackPublishedAsset(db, asset)) return { asset, audience: "pack-member" };
  throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
}

function assetExtension(mimeType: string): string {
  return mimeType === "image/png" ? "png"
    : mimeType === "image/gif" ? "gif"
      : mimeType === "video/mp4" ? "mp4"
        : mimeType === "video/webm" ? "webm"
          : mimeType === "image/webp" ? "webp" : "jpg";
}

export async function createAssetDownload(db: Database, requesterId: string, assetId: string) {
  const { asset, audience } = await getReadableAsset(db, requesterId, assetId);
  if (asset.state !== "ready") throw new ApiError(409, "ASSET_NOT_READY", "The asset is not ready");
  const extension = assetExtension(asset.mimeType);
  const generic = `sticker-${asset.kind}-${asset.id}.${extension}`;
  // A borrowed asset never carries the creator's own filename — that is their upload, not the
  // installer's, and it can leak anything they happened to name the file.
  const filename = audience === "owner" ? asset.originalFilename ?? generic : generic;
  const download = await getObjectStore().signedGet(asset.r2Key, filename);
  return { url: download.url, expiresAt: download.expiresAt.toISOString(), asset: serializeAsset(asset) };
}

/** Inline media URL for web previews: the requester's own art, or published marketplace art. */
export async function createAssetPreview(db: Database, requesterId: string, assetId: string) {
  const { asset } = await getReadableAsset(db, requesterId, assetId);
  if (asset.state !== "ready") throw new ApiError(409, "ASSET_NOT_READY", "The asset is not ready");
  const preview = await getObjectStore().signedGet(asset.r2Key);
  return { url: preview.url, expiresAt: preview.expiresAt.toISOString(), asset: serializeAsset(asset) };
}

export function serializeAsset(asset: typeof assets.$inferSelect) {
  return {
    id: asset.id,
    stickerId: asset.stickerId,
    kind: asset.kind,
    state: asset.state,
    mimeType: asset.mimeType,
    byteSize: asset.byteSize,
    width: asset.width,
    height: asset.height,
    frameCount: asset.frameCount,
    durationSeconds: asset.durationSeconds,
    fps: asset.fps,
    sha256: asset.sha256,
    hasAlpha: asset.hasAlpha,
    createdAt: asset.createdAt.toISOString(),
  };
}

export async function purgeStickerMediaImmediately(db: Database, ownerId: string, stickerId: string): Promise<void> {
  const rows = await db.select().from(assets).where(and(eq(assets.ownerId, ownerId), eq(assets.stickerId, stickerId)));
  const store = getObjectStore();
  for (const asset of rows) await store.delete(asset.r2Key);
  await db.delete(stickers).where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId)));
}

export async function purgeStaleUnboundUploads(db: Database, olderThan = new Date(Date.now() - 24 * 60 * 60 * 1000)) {
  const rows = await db.select().from(assets).where(and(isNull(assets.stickerId), lt(assets.createdAt, olderThan)));
  const store = getObjectStore();
  let purged = 0;
  for (const asset of rows) {
    await store.delete(asset.r2Key);
    await db.delete(assets).where(and(eq(assets.id, asset.id), isNull(assets.stickerId)));
    purged += 1;
  }
  return purged;
}
