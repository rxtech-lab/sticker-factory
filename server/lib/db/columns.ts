import { sql } from "drizzle-orm";
import { alias } from "drizzle-orm/sqlite-core";
import { assets, stickerRevisions } from "@/lib/db/schema";

/**
 * The joined-asset aliases and preview-resolution SQL every summary query shares.
 *
 * This lives in a leaf module rather than in `lib/services/stickers.ts` because `assets.ts` and
 * `packs.ts` both need it and `stickers.ts` already imports `assets.ts` — importing back would
 * close a cycle.
 */
export const systemAssets = alias(assets, "system_assets");
export const previewAssets = alias(assets, "preview_assets");

/**
 * The asset a client shows for a revision, as SQL so a summary join can resolve it in the same
 * round trip. Mirrors the per-kind fallback chain the clients expect: animated prefers the sharing
 * rendition, static prefers the PNG, and both fall back through the preview to the master.
 *
 * The sharing rendition is two columns because it used to be a GIF. `apng_asset_id` comes first and
 * `gif_asset_id` is what a revision published before the switch still resolves through; exactly one
 * of them is ever set on a given revision, so the coalesce is a fallback in name only.
 */
export const previewAssetIdSql = sql`case when ${stickerRevisions.kind} = 'animated' then coalesce(${stickerRevisions.apngAssetId}, ${stickerRevisions.gifAssetId}, ${stickerRevisions.systemAssetId}, ${stickerRevisions.previewAssetId}, ${stickerRevisions.masterAssetId}) else coalesce(${stickerRevisions.pngAssetId}, ${stickerRevisions.previewAssetId}, ${stickerRevisions.masterAssetId}) end`;
