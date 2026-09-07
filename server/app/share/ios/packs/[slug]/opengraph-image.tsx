import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { getPublicPack } from "@/lib/services/public-packs";
import { shareImage, shareThumbnail } from "@/lib/share-image";

export const alt = "Preview a sticker pack in Sticker Factory";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export default async function Image({ params }: { params: Promise<{ slug: string }> }) {
  try {
    const pack = await getPublicPack(await getDatabase(), (await params).slug);
    const thumbnails = await Promise.all(pack.stickers.slice(0, 3).map(sticker => shareThumbnail(sticker.previewURL)));
    const count = pack.stickers.length;
    return shareImage({ title: pack.title, subtitle: `by ${pack.creator.displayName} · ${count} ${count === 1 ? "sticker" : "stickers"}`, pack: true, thumbnails });
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      return new Response("Pack unavailable", { status: 404, headers: { "Cache-Control": "no-store" } });
    }
    throw error;
  }
}
