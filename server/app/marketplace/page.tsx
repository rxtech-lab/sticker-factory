import Link from "next/link";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { PackGrid } from "@/components/pack-grid";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { signPackCovers } from "@/lib/services/pack-previews";
import { listMarketplacePacks, listOwnPacks } from "@/lib/services/packs";

export const metadata = { title: "Marketplace" };

export default async function MarketplacePage({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  await connection();
  // Signed-in only: every card needs a viewer to resolve `installed`/`isMine` and to sign covers.
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");

  const query = await searchParams;
  const mine = query.mine === "true";
  const sort = query.sort === "popular" ? "popular" : "recent";
  const search = typeof query.q === "string" ? query.q : "";
  const cursor = typeof query.cursor === "string" ? query.cursor : undefined;

  const db = await getDatabase();
  const result = mine
    ? await listOwnPacks(db, ownerId, { cursor, limit: 24 })
    : await listMarketplacePacks(db, ownerId, { cursor, limit: 24, sort, query: search });
  const covers = await signPackCovers(db, ownerId, result.data);

  const nextHref = result.nextCursor
    ? `/marketplace?${new URLSearchParams({
      ...(mine ? { mine: "true" } : { sort }),
      ...(search ? { q: search } : {}),
      cursor: result.nextCursor,
    }).toString()}`
    : null;

  return (
    <main className="shell marketplace-page">
      <header className="page-heading">
        <div>
          <div className="eyebrow">Marketplace</div>
          <h1>{mine ? "Your sticker packs" : "Sticker packs"}</h1>
          <p>
            {mine
              ? "Bundle your published stickers and share them with everyone."
              : "Add a pack and its stickers show up in your library and in Messages."}
          </p>
        </div>
        <Link className="pill-button" href="/marketplace/new">New pack</Link>
      </header>

      <nav className="filter-row" aria-label="Marketplace filters">
        <Link className={!mine && sort === "recent" ? "filter active" : "filter"} href="/marketplace">Newest</Link>
        <Link className={!mine && sort === "popular" ? "filter active" : "filter"} href="/marketplace?sort=popular">Popular</Link>
        <Link className={mine ? "filter active" : "filter"} href="/marketplace?mine=true">My packs</Link>
      </nav>

      {!mine && (
        <form className="pack-search" action="/marketplace" method="get">
          <label className="visually-hidden" htmlFor="pack-search-input">Search packs</label>
          <input id="pack-search-input" name="q" defaultValue={search} placeholder="Search packs by name" />
          <input type="hidden" name="sort" value={sort} />
          <button className="secondary-button" type="submit">Search</button>
        </form>
      )}

      {result.data.length === 0 ? (
        <section className="empty-state glass-panel">
          <div className="empty-icon">✦</div>
          <h2>{mine ? "You have not made a pack yet" : "Nothing here yet"}</h2>
          <p>
            {mine
              ? "Create a pack from stickers you have already published."
              : search
                ? `No packs match “${search}”.`
                : "Be the first to publish a sticker pack."}
          </p>
        </section>
      ) : (
        <PackGrid packs={result.data} previews={covers} />
      )}

      {nextHref && <div className="pagination"><Link className="secondary-button" href={nextHref}>Next page</Link></div>}
    </main>
  );
}
