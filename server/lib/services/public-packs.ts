import { and, eq, inArray } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { stickerPacks } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getPack } from "./packs";
import { signStickerPreviews } from "./pack-previews";

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
      kind: sticker.kind, previewURL: previews.get(sticker.id) ?? null })) };
}
