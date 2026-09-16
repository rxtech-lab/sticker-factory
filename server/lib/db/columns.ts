import { sql } from "drizzle-orm";
import { alias } from "drizzle-orm/pg-core";
import { assets, plans, stickerRevisions, stickers } from "@/lib/db/schema";

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
 * The smaller sizes WinkySticker can attach. There is no alias for Large: Large *is* the preview
 * asset above, which every summary already joins.
 */
export const attachmentMediumAssets = alias(assets, "attachment_medium_assets");
export const attachmentSmallAssets = alias(assets, "attachment_small_assets");
/**
 * The WebP copy of the sharing rendition. Joined rather than folded into `previewAssetIdSql`,
 * because it must never *replace* the preview: a client that cannot decode WebP has to keep
 * resolving through to the APNG, and a chain that coalesced the two would hand it a file it cannot
 * open.
 */
export const webpAssets = alias(assets, "webp_assets");
/**
 * The two messenger renditions, joined for the same reason the WebP is and with the same rule: they
 * sit beside the preview chain and never inside it. A Telegram rendition can be a VP9 WebM, which
 * no surface in this app can draw — resolving a preview through to one would leave the library
 * showing nothing.
 */
export const whatsappAssets = alias(assets, "whatsapp_assets");
export const telegramAssets = alias(assets, "telegram_assets");

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

/** The concept render of the plan a draft is being built from. */
export const planConceptAssets = alias(assets, "plan_concept_assets");

/**
 * The newest plan concept render on a *draft* sticker, as SQL so a summary join resolves it in the
 * same round trip.
 *
 * A draft that has not built anything yet has no revision and therefore no artwork, and the grid
 * used to draw the kind glyph for every one of them — a wall of identical film strips that says
 * nothing about which project is which. The plan's concept render is the picture the user already
 * approved, so it is the closest thing the draft has to a cover.
 *
 * Gated on `draft` inside the CASE rather than filtered afterwards: a published sticker always has
 * its own artwork, and skipping the correlated lookup keeps listing cost where it was for every row
 * that already had a cover.
 */
export const planConceptAssetIdSql = sql<string | null>`case when ${stickers.status} = 'draft' then (
  select ${plans.conceptAssetId} from ${plans}
  where ${plans.stickerId} = ${stickers.id} and ${plans.conceptAssetId} is not null
  order by ${plans.updatedAt} desc limit 1
) end`;
