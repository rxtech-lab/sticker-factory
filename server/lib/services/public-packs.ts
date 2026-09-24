import { and, eq, inArray, isNull } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { stickerPackItems, stickerPacks, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
import { getPack } from "./packs";
import { signStickerPreviews } from "./pack-previews";
import { describePlaybackAsset, loadPlaybackPayload } from "./playback";

/** Explicit public projection: never serialize owner/account fields or draft assets. */
export async function getPublicPack(db: Database, slug: string) {
  const row = await db.select().from(stickerPacks).where(and(
    eq(stickerPacks.slug, slug), inArray(stickerPacks.state, ["published", "unlisted"]),
  )).then(firstRow);
  if (!row) throw new ApiError(404, "PACK_NOT_FOUND", "This sticker pack is no longer available.");
  const pack = await getPack(db, row.creatorId, slug);
  // Recheck after the second read in case the creator removed the pack concurrently.
  if (pack.state !== "published" && pack.state !== "unlisted") throw new ApiError(404, "PACK_NOT_FOUND", "This sticker pack is no longer available.");
  const previews = await signStickerPreviews(db, row.creatorId, pack.stickers);
  return { id: pack.id, slug: pack.slug, title: pack.title, summary: pack.summary,
    creator: { handle: pack.creator.handle, displayName: pack.creator.displayName },
    stickers: pack.stickers.map((sticker) => ({ id: sticker.id, title: sticker.title,
      kind: sticker.kind, playbackRevisionId: sticker.playbackRevisionId ?? null,
      previewURL: previews.get(sticker.id) ?? null })) };
}

/**
 * The published pose bundle of one sticker in a shared pack, for viewers without an account.
 *
 * Access follows the pack link itself: the pack must still be shared and still contain the
 * sticker. Assets carry short-lived signed URLs because the caller cannot use `/assets/download`.
 */
export async function getPublicPackPlayback(db: Database, slug: string, stickerId: string) {
  const row = await db.select({ revision: stickerRevisions }).from(stickerPacks)
    .innerJoin(stickerPackItems, eq(stickerPackItems.packId, stickerPacks.id))
    .innerJoin(stickers, eq(stickers.id, stickerPackItems.stickerId))
    .innerJoin(stickerRevisions, eq(stickerRevisions.id, stickers.activeRevisionId))
    .where(and(
      eq(stickerPacks.slug, slug), inArray(stickerPacks.state, ["published", "unlisted"]),
      eq(stickers.id, stickerId), eq(stickers.status, "published"), isNull(stickers.deletedAt),
    ))
    .then(firstRow);
  if (!row?.revision.playbackJson) throw new ApiError(404, "PLAYBACK_NOT_FOUND", "This sticker's poses are not available.");
  const { rows, ...payload } = await loadPlaybackPayload(db, stickerId, row.revision);
  const store = getObjectStore();
  const signed = await Promise.all(rows.map(async (asset) => {
    const preview = await store.signedGet(asset.r2Key);
    return { ...describePlaybackAsset(asset), url: preview.url, expiresAt: preview.expiresAt.toISOString() };
  }));
  return { ...payload, assets: signed };
}
