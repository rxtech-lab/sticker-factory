import { and, desc, eq, inArray, isNotNull, isNull } from "drizzle-orm";
import sharp from "sharp";
import { StickerDocumentSchema, canonicalJson, documentRenderableLayers, layerImageAssetIds, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, packInstalls, stickerPackItems, stickerPacks, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { validateDocumentAssetReferences } from "./sticker-documents";
import { derivedAssetId, getReadyOwnedAssets } from "./assets";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";

export type PlaybackBundle = { version: 1; document: StickerDocument; assetIds: string[] };

/** Only the prepared, published bundle is readable by installed-pack users. */
export async function readablePlayback(db: Database, requesterId: string, stickerId: string, revisionId?: string) {
  const row = await db.select({ sticker: stickers, revision: stickerRevisions }).from(stickers)
    .innerJoin(stickerRevisions, eq(stickerRevisions.id, stickers.activeRevisionId))
    .where(and(eq(stickers.id, stickerId), eq(stickers.status, "published"), isNull(stickers.deletedAt)))
    .then(firstRow);
  if (!row || !row.revision.playbackJson || (revisionId && row.revision.id !== revisionId)) {
    throw new ApiError(404, "PLAYBACK_NOT_FOUND", "This sticker's controls are not available. Refresh your library.");
  }
  if (row.sticker.ownerId !== requesterId && !await installedByRequester(db, requesterId, stickerId)) {
    throw new ApiError(404, "PLAYBACK_NOT_FOUND", "This sticker's controls are not available");
  }
  return row;
}

/**
 * The sticker's current published look, or — while it is a draft again, edited or mid-publish — the
 * last look it was published with. Only deleting the sticker, or losing access to it, takes that
 * away: a pet or a posed sticker keeps playing its old self until the new one is published.
 *
 * `revisionId` pins the answer to one revision, current or last published; any other is not found.
 */
export async function lastPublishedPlayback(db: Database, requesterId: string, stickerId: string, revisionId?: string) {
  try {
    return await readablePlayback(db, requesterId, stickerId, revisionId);
  } catch (error) {
    if (!(error instanceof ApiError && error.status === 404)) throw error;
    const sticker = await db.select().from(stickers)
      .where(and(eq(stickers.id, stickerId), isNull(stickers.deletedAt))).then(firstRow);
    if (!sticker || (sticker.ownerId !== requesterId && !await installedByRequester(db, requesterId, stickerId))) throw error;
    // A published revision is the one `bindExports` minted with the renditions and the bundle.
    const revision = await db.select().from(stickerRevisions)
      .where(and(eq(stickerRevisions.stickerId, stickerId), isNotNull(stickerRevisions.playbackJson), isNotNull(stickerRevisions.systemAssetId)))
      .orderBy(desc(stickerRevisions.createdAt)).limit(1).then(firstRow);
    if (!revision || (revisionId && revision.id !== revisionId)) throw error;
    return { sticker, revision };
  }
}

async function installedByRequester(db: Database, requesterId: string, stickerId: string): Promise<boolean> {
  return !!await db.select({ id: stickerPackItems.packId }).from(stickerPackItems)
    .innerJoin(stickerPacks, eq(stickerPacks.id, stickerPackItems.packId))
    .innerJoin(packInstalls, eq(packInstalls.packId, stickerPacks.id))
    .where(and(eq(stickerPackItems.stickerId, stickerId), eq(packInstalls.userId, requesterId),
      eq(packInstalls.state, "installed"), inArray(stickerPacks.state, ["published", "unlisted"])))
    .limit(1).then(firstRow);
}

export async function getStickerPlayback(db: Database, requesterId: string, stickerId: string, revisionId?: string) {
  const { revision } = await lastPublishedPlayback(db, requesterId, stickerId, revisionId);
  const { rows, ...payload } = await loadPlaybackPayload(db, stickerId, revision);
  return { ...payload, assets: rows.map(describePlaybackAsset) };
}

/** Shared by the authenticated and public-pack readers once each has checked access. */
export async function loadPlaybackPayload(db: Database, stickerId: string, revision: typeof stickerRevisions.$inferSelect) {
  const bundle = revision.playbackJson!;
  const rows = bundle.assetIds.length ? await db.select().from(assets)
    .where(and(inArray(assets.id, bundle.assetIds), eq(assets.kind, "playback"), eq(assets.state, "ready"))) : [];
  if (rows.length !== bundle.assetIds.length) throw new ApiError(409, "PLAYBACK_INCOMPLETE", "Some playback artwork is unavailable");
  return { stickerId, revisionId: revision.id, version: 1 as const, document: StickerDocumentSchema.parse(bundle.document), rows };
}

export function describePlaybackAsset(asset: typeof assets.$inferSelect) {
  return { id: asset.id, mimeType: asset.mimeType, byteSize: asset.byteSize,
    sha256: asset.sha256, width: asset.width, height: asset.height };
}

/** Publication creates new raster derivatives. Original source IDs never enter the runtime bundle. */
export async function preparePlaybackBundle(
  db: Database, ownerId: string, stickerId: string, revisionId: string,
  source: StickerDocument, prepared?: StickerDocument,
): Promise<PlaybackBundle | null> {
  if (!source.configuration) return null;
  const document = structuredClone(prepared ?? source);
  if (prepared) {
    // Clients may rasterize private masks/SVG and key video into frames, but may not alter controls,
    // animation, layout, or the composition while binding it to somebody's approved revision.
    const structure = (value: StickerDocument) => ({
      canvas: value.canvas, kind: value.kind, durationSeconds: value.durationSeconds, fps: value.fps,
      loop: value.loop, speed: value.speed, configuration: value.configuration,
      layers: value.layers.map((layer) => ({ id: layer.id, name: layer.name, anchor: layer.anchor,
        animations: layer.animations, animation: layer.animation, hidden: layer.hidden, blendMode: layer.blendMode })),
    });
    const allowedLayers = prepared.layers.length === source.layers.length && prepared.layers.every((layer, index) => {
      const prior = source.layers[index];
      if (prior.type === "video" && layer.type === "sequence") {
        return layer.contentMode === prior.contentMode && layer.startSeconds === prior.startSeconds
          && layer.playback === prior.playback && Math.abs(layer.frameCount / layer.frameRate - prior.frameCount / prior.frameRate) < 0.001;
      }
      return canonicalJson(prior) === canonicalJson(layer);
    });
    if (!allowedLayers || canonicalJson(structure(source)) !== canonicalJson(structure(prepared)) || canonicalJson(source.background) !== canonicalJson(prepared.background)) {
      throw new ApiError(422, "PLAYBACK_REVISION_MISMATCH", "Playback controls and motion must match the accepted revision");
    }
  }
  await validateDocumentAssetReferences(db, ownerId, stickerId, document);
  const store = getObjectStore();
  const cache = new Map<string, string>();
  const outputIds = new Set<string>();
  const raster = async (assetId: string, maskAssetId?: string, grid?: { columns: number; rows: number; frameCount: number }): Promise<string> => {
    const key = `${assetId}:${maskAssetId ?? ""}:${grid ? `${grid.columns}:${grid.rows}:${grid.frameCount}` : ""}`;
    if (cache.has(key)) return cache.get(key)!;
    const [original] = await getReadyOwnedAssets(db, ownerId, [assetId]);
    if (original.stickerId !== stickerId || !original.mimeType.startsWith("image/")) {
      throw new ApiError(422, "INVALID_PLAYBACK_SOURCE", "Playback artwork must belong to this sticker");
    }
    const id = derivedAssetId(revisionId, `playback:${key}`);
    const prior = await db.select().from(assets).where(and(eq(assets.id, id), eq(assets.state, "ready"))).then(firstRow);
    if (!prior) {
      const input = await store.get(original.r2Key);
      let image = sharp(input.bytes).ensureAlpha();
      if (maskAssetId) {
        const [mask] = await getReadyOwnedAssets(db, ownerId, [maskAssetId]);
        if (mask.stickerId !== stickerId) throw new ApiError(422, "INVALID_PLAYBACK_SOURCE", "Mask belongs to another sticker");
        const maskBytes = await sharp((await store.get(mask.r2Key)).bytes).resize(original.width!, original.height!, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer();
        image = image.composite([{ input: maskBytes, blend: "dest-in" }]);
      }
      let bytes = await image.png().toBuffer();
      if (grid) {
        const width = Math.floor(original.width! / grid.columns), height = Math.floor(original.height! / grid.rows);
        const cells = await Promise.all(Array.from({ length: grid.frameCount }, async (_, index) => ({
          input: await sharp(bytes).extract({ left: index % grid.columns * width, top: Math.floor(index / grid.columns) * height, width, height }).png().toBuffer(),
          left: index % grid.columns * width, top: Math.floor(index / grid.columns) * height,
        })));
        bytes = await sharp({ create: { width: width * grid.columns, height: height * grid.rows, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite(cells).png().toBuffer();
      }
      if (bytes.length >= 25 * 1024 * 1024) throw new ApiError(422, "PLAYBACK_TOO_LARGE", "Playback artwork must be smaller than 25 MB");
      const inspection = await inspectImage(bytes);
      const r2Key = objectKey(ownerId, id, "image/png");
      await store.put(r2Key, { bytes, contentType: "image/png", metadata: { sha256: inspection.sha256 } });
      await db.insert(assets).values({ id, ownerId, stickerId, kind: "playback", state: "ready", r2Key,
        mimeType: "image/png", byteSize: inspection.byteSize, sha256: inspection.sha256,
        width: inspection.width, height: inspection.height, hasAlpha: inspection.hasTransparentPixels,
        frameCount: original.frameCount, fps: original.fps, durationSeconds: original.durationSeconds,
        sequenceColumns: original.sequenceColumns, sequenceRows: original.sequenceRows, readyAt: new Date(),
      }).onConflictDoUpdate({ target: assets.id, set: { state: "ready", byteSize: inspection.byteSize, sha256: inspection.sha256, width: inspection.width, height: inspection.height, hasAlpha: inspection.hasTransparentPixels, readyAt: new Date() } });
    }
    cache.set(key, id); outputIds.add(id); return id;
  };
  for (const layer of document.layers) {
    if (layer.type === "video") throw new ApiError(422, "PLAYBACK_VIDEO_REQUIRED", "Prepare the video's transparent playback frames before publishing");
    if (layer.type === "image") { layer.assetId = await raster(layer.assetId, layer.maskAssetId); delete layer.maskAssetId; }
    if (layer.type === "sequence") {
      layer.assetId = await raster(layer.assetId, undefined, layer);
      if (layer.posterAssetId) layer.posterAssetId = await raster(layer.posterAssetId);
    }
    // Every sheet a control can select, not just the default clip: the client composites whichever
    // clip and face the viewer picks, so all of them have to be in the bundle.
    if (layer.type === "sprite") {
      for (const clip of layer.clips) {
        const grid = { columns: clip.columns, rows: clip.rows, frameCount: clip.frames.length };
        clip.assetId = await raster(clip.assetId, undefined, grid);
        // A masked clip draws its face through this aperture, so it ships like the body sheet.
        if (clip.faceMaskAssetId) clip.faceMaskAssetId = await raster(clip.faceMaskAssetId, undefined, grid);
        // The raw generated sheet exists only to re-register faces; it never plays back.
        delete clip.faceSourceAssetId;
      }
      layer.expressions.assetId = await raster(layer.expressions.assetId, undefined, {
        columns: layer.expressions.columns, rows: layer.expressions.rows, frameCount: layer.expressions.tiles.length,
      });
      layer.posterAssetId = await raster(layer.posterAssetId);
    }
    if (layer.type === "svg" && layer.posterAssetId) layer.posterAssetId = await raster(layer.posterAssetId);
    if (layer.type === "svg" && layer.source.kind === "asset") {
      const [svg] = await getReadyOwnedAssets(db, ownerId, [layer.source.assetId]);
      if (svg.stickerId !== stickerId || svg.mimeType !== "image/svg+xml") throw new ApiError(422, "INVALID_PLAYBACK_SOURCE", "Invalid vector artwork");
      const markup = Buffer.from((await store.get(svg.r2Key)).bytes).toString("utf8").replace(/<!--[\s\S]*?-->/g, "").replace(/<metadata\b[^>]*>[\s\S]*?<\/metadata>/gi, "");
      layer.source = { kind: "inline", markup };
    }
  }
  if (document.background.type === "image") document.background.assetId = await raster(document.background.assetId);
  for (const variant of document.configuration?.variants ?? []) for (const patch of variant.layers) {
    if (patch.source && patch.source.kind !== "base") {
      patch.source.assetId = await raster(patch.source.assetId, undefined, patch.source.kind === "sequence" ? patch.source : undefined);
      if (patch.source.kind === "sequence" && patch.source.posterAssetId) patch.source.posterAssetId = await raster(patch.source.posterAssetId);
    }
  }
  const parsed = StickerDocumentSchema.parse(document);
  const referenced = documentRenderableLayers(parsed).flatMap(layerImageAssetIds);
  if (referenced.some((id) => !outputIds.has(id))) throw new ApiError(422, "PLAYBACK_INCOMPLETE", "Playback still references private source artwork");
  const preparedAssets = await getReadyOwnedAssets(db, ownerId, [...outputIds]);
  for (const asset of preparedAssets) {
    if (asset.kind !== "playback" || asset.stickerId !== stickerId) throw new ApiError(422, "PLAYBACK_INCOMPLETE", "Playback derivative is invalid");
    const metadata = await store.head(asset.r2Key);
    if (metadata.byteSize !== asset.byteSize) throw new ApiError(422, "PLAYBACK_INCOMPLETE", "Playback derivative is missing or incomplete");
  }
  return { version: 1, document: parsed, assetIds: [...outputIds].sort() };
}
