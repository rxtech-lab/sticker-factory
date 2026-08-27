import Link from "next/link";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { createAssetPreview } from "@/lib/services/assets";
import { listInstalledPacks } from "@/lib/services/packs";
import { listStickers } from "@/lib/services/stickers";

export const metadata = { title: "Library" };

export default async function LibraryPage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");
  const query = await searchParams;
  const kind = query.kind === "static" || query.kind === "animated" ? query.kind : undefined;
  const db = getDatabase();
  const cursor = typeof query.cursor === "string" ? query.cursor : undefined;
  const result = await listStickers(db, ownerId, { kind, cursor, limit: 24 });
  const installedPacks = await listInstalledPacks(db, ownerId);
  const previewUrls = new Map<string, string>();
  await Promise.all(result.data.map(async (sticker) => {
    const assetId = sticker.kind === "animated" ? sticker.systemSticker?.assetId ?? sticker.previewAsset?.id : sticker.previewAsset?.id;
    if (!assetId) return;
    try { previewUrls.set(sticker.id, (await createAssetPreview(db, ownerId, assetId)).url); } catch { /* Keep metadata card available. */ }
  }));
  return (
    <main className="shell library-page">
      <header className="page-heading">
        <div><div className="eyebrow">Private collection</div><h1>Your sticker library</h1><p>Browse, compare, download, or remove projects created in the iOS app.</p></div>
        <div className="platform-note glass-panel"><strong>Create on iOS</strong><span>Generation and editing stay in the native app.</span></div>
      </header>
      <nav className="filter-row" aria-label="Library filters">
        <Link className={!kind ? "filter active" : "filter"} href="/library">All</Link>
        <Link className={kind === "static" ? "filter active" : "filter"} href="/library?kind=static">Static</Link>
        <Link className={kind === "animated" ? "filter active" : "filter"} href="/library?kind=animated">Animated</Link>
      </nav>
      {/*
        The grid below is this user's own stickers only. Added packs stay their own sections in the
        iOS library and the Messages grid; here they are links, so the web page keeps its single
        meaning of "projects you can open and edit".
      */}
      {installedPacks.length > 0 && (
        <nav className="library-section-strip" aria-label="Added sticker packs">
          <span>Added packs:</span>
          {installedPacks.map((pack) => (
            <Link href={`/marketplace/${pack.slug}`} key={pack.id}>
              {pack.title} <span aria-hidden="true">·</span> {pack.itemCount}
            </Link>
          ))}
        </nav>
      )}
      {result.data.length === 0 ? (
        <section className="empty-state glass-panel"><div className="empty-icon">✦</div><h2>No stickers yet</h2><p>Open Sticker Factory on iPhone or iPad to create your first {kind ?? ""} sticker.</p></section>
      ) : (
        <section className="sticker-grid">
          {result.data.map((sticker) => (
            <Link className="sticker-card glass-panel" href={`/library/${sticker.id}`} key={sticker.id}>
              <div className={`sticker-preview placeholder-${sticker.kind}`}>
                {previewUrls.get(sticker.id)
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img src={previewUrls.get(sticker.id)} alt={`${sticker.title} preview`} />
                  : <span>{sticker.kind === "animated" ? "◌" : "✦"}</span>}
              </div>
              <div className="sticker-card-copy"><div><h2>{sticker.title}</h2><p>{sticker.kind} · {sticker.status}</p></div><span aria-hidden="true">→</span></div>
            </Link>
          ))}
        </section>
      )}
      {result.nextCursor && <div className="pagination"><Link className="secondary-button" href={`/library?${new URLSearchParams({ ...(kind ? { kind } : {}), cursor: result.nextCursor }).toString()}`}>Next page</Link></div>}
    </main>
  );
}
