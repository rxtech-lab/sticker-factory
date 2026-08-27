import type { Database } from "@/lib/db/client";
import { createAssetPreview } from "@/lib/services/assets";
import type { PackSummaryV1 } from "@/lib/services/packs";

type StickerLike = { id: string; kind: string; systemSticker: { assetId: string } | null; previewAsset: { id: string } | null };

/**
 * The asset a web card should render for a sticker.
 *
 * The system rendition first for animated stickers: both show the same artwork, but an animated
 * sticker's preview is the 1024² sharing GIF — tens of megabytes to fill a thumbnail the system
 * rendition covers in under 500 KB. This mirrors what the iOS library card does.
 */
export function thumbnailAssetId(sticker: StickerLike): string | undefined {
  return sticker.kind === "animated"
    ? sticker.systemSticker?.assetId ?? sticker.previewAsset?.id
    : sticker.previewAsset?.id ?? sticker.systemSticker?.assetId;
}

/**
 * Signed inline URLs for a list of stickers, keyed by sticker id.
 *
 * A failure is swallowed per sticker: a card with no image is still a usable card, and one
 * unreadable asset must not blank a whole page.
 */
export async function signStickerPreviews(
  db: Database,
  viewerId: string,
  stickers: StickerLike[],
): Promise<Map<string, string>> {
  const urls = new Map<string, string>();
  await Promise.all(stickers.map(async (sticker) => {
    const assetId = thumbnailAssetId(sticker);
    if (!assetId) return;
    try {
      urls.set(sticker.id, (await createAssetPreview(db, viewerId, assetId)).url);
    } catch {
      // Keep the metadata card available.
    }
  }));
  return urls;
}

/** Cover mosaics for a page of packs, keyed by pack id. */
export async function signPackCovers(
  db: Database,
  viewerId: string,
  packs: PackSummaryV1[],
): Promise<Map<string, string[]>> {
  const covers = new Map<string, string[]>();
  await Promise.all(packs.map(async (pack) => {
    const urls = await signStickerPreviews(db, viewerId, pack.coverStickers);
    covers.set(pack.id, pack.coverStickers.map((sticker) => urls.get(sticker.id)).filter((url): url is string => Boolean(url)));
  }));
  return covers;
}
