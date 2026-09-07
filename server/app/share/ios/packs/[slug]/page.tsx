import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { cache } from "react";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { getPublicPack } from "@/lib/services/public-packs";
import { APP_STORE_URL, packShareURL, shareMetadata } from "@/lib/sharing";
const load = cache(async (slug: string) => {
  try { return await getPublicPack(await getDatabase(), slug); }
  catch (error) { if (error instanceof ApiError && error.status === 404) notFound(); throw error; }
});
type Props = { params: Promise<{ slug: string }> };
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const pack = await load((await params).slug);
  return shareMetadata({
    title: pack.title,
    description: pack.summary ?? `Stickers by ${pack.creator.displayName}`,
    url: packShareURL(pack.slug),
    imageAlt: `${pack.title} by ${pack.creator.displayName} — sticker pack preview`,
  });
}
export default async function SharedPackPage({ params }: Props) {
  const pack = await load((await params).slug);
  return <main className="shell pack-detail-page">
    <header className="page-heading"><div><div className="eyebrow">Sticker pack</div>
      <h1>{pack.title}</h1><p>{pack.summary}</p><p>by {pack.creator.displayName}</p></div>
      <a className="pill-button" href={APP_STORE_URL}>Install in Sticker Factory</a></header>
    <section className="sticker-grid">{pack.stickers.map((sticker) => <article className="sticker-card glass-panel" key={sticker.id}>
      <div className="sticker-preview">{sticker.previewURL
        // eslint-disable-next-line @next/next/no-img-element
        ? <img src={sticker.previewURL} alt={sticker.title} /> : <span>Preview unavailable</span>}</div>
      <div className="sticker-card-copy"><h2>{sticker.title}</h2></div>
    </article>)}</section>
    {!pack.stickers.length && <p>No stickers are available in this pack yet.</p>}
  </main>;
}
