import { createHash } from "node:crypto";
import { and, eq, inArray, isNull, lt, or, sql } from "drizzle-orm";
import type { CreateUploadRequest } from "@/lib/contracts/api";
import { MAX_RENDITION_SECONDS } from "@/lib/contracts/sticker";
import type { Database } from "@/lib/db/client";
import { previewAssetIdSql } from "@/lib/db/columns";
import { assets, stickerPackItems, stickerPacks, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  getObjectStore,
  inspectImage,
  inspectMp4,
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

async function assertOwnedSticker(db: Database, ownerId: string, stickerId?: string): Promise<void> {
  if (!stickerId) return;
  const sticker = await db.select({ id: stickers.id, deletedAt: stickers.deletedAt }).from(stickers)
    .where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId))).get();
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
    createdAt: new Date(),
  });
  const upload = await getObjectStore().signedPut(r2Key, request.mimeType, request.byteSize);
  return {
    asset: { id, kind: request.kind, state: "pending", mimeType: request.mimeType, byteSize: request.byteSize },
    upload: { url: upload.url, expiresAt: upload.expiresAt.toISOString(), headers: upload.headers },
  };
}

function validateImageForKind(
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
    if (inspection.frameCount > 1 && (inspection.durationSeconds < 0.5 || inspection.durationSeconds > MAX_RENDITION_SECONDS || inspection.fps > 30.01)) {
      throw new ApiError(422, "INVALID_SYSTEM_ANIMATION", `Animated system stickers must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
  if (asset.kind === "gif") {
    if (inspection.mimeType !== "image/gif" || inspection.width !== 1024 || inspection.height !== 1024 || inspection.frameCount < 2
      || !inspection.hasAlpha || !inspection.hasTransparentPixels) {
      throw new ApiError(422, "INVALID_GIF_EXPORT", "Animated sharing GIFs must be animated 1024x1024 GIF files");
    }
    if (inspection.durationSeconds < 0.5 || inspection.durationSeconds > MAX_RENDITION_SECONDS || inspection.fps > 30.01) {
      throw new ApiError(422, "INVALID_GIF_TIMING", `Animated sharing GIFs must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
    }
  }
}

export async function completeUpload(db: Database, ownerId: string, assetId: string, expectedSha256?: string) {
  const asset = await db.select().from(assets)
    .where(and(eq(assets.id, assetId), eq(assets.ownerId, ownerId))).get();
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
  if (IMAGE_TYPES.has(asset.mimeType)) {
    inspection = await inspectImage(object.bytes);
    validateImageForKind(asset, inspection);
  } else if (asset.kind === "mp4" && asset.mimeType === "video/mp4") {
    mp4Inspection = inspectMp4(object.bytes);
    if (mp4Inspection.width !== 1024 || mp4Inspection.height !== 1024) {
      throw new ApiError(422, "INVALID_MP4_DIMENSIONS", "MP4 exports must be 1024x1024");
    }
  } else {
    throw new ApiError(422, "UNSUPPORTED_MEDIA", "This asset kind requires an image");
  }

  const actualSha256 = inspection?.sha256 ?? mp4Inspection?.sha256
    ?? (await import("node:crypto")).createHash("sha256").update(object.bytes).digest("hex");
  const requiredSha = expectedSha256 ?? asset.sha256;
  if (requiredSha && requiredSha.toLowerCase() !== actualSha256) {
    throw new ApiError(422, "CHECKSUM_MISMATCH", "The uploaded object checksum is invalid");
  }

  const [ready] = await db.update(assets).set({
    state: "ready",
    byteSize: object.bytes.byteLength,
    width: inspection?.width ?? mp4Inspection?.width,
    height: inspection?.height ?? mp4Inspection?.height,
    frameCount: inspection?.frameCount ?? mp4Inspection?.frameCount,
    durationSeconds: inspection?.durationSeconds ?? mp4Inspection?.durationSeconds,
    fps: inspection?.fps ?? mp4Inspection?.fps,
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
    .where(and(eq(assets.id, assetId), eq(assets.ownerId, ownerId))).get();
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
const PACK_SHARED_ASSET_KINDS = ["system", "preview", "gif", "master"] as const;

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
      ),
    ))
    .limit(1)
    .get();
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
  const asset = await db.select().from(assets).where(eq(assets.id, assetId)).get();
  if (!asset || asset.state === "deleted") throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
  if (asset.ownerId === requesterId) return { asset, audience: "owner" };
  if (await isPackPublishedAsset(db, asset)) return { asset, audience: "pack-member" };
  throw new ApiError(404, "ASSET_NOT_FOUND", "Asset not found");
}

function assetExtension(mimeType: string): string {
  return mimeType === "image/png" ? "png"
    : mimeType === "image/gif" ? "gif"
      : mimeType === "video/mp4" ? "mp4"
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
