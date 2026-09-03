import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { PackGrid } from "@/components/pack-grid";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { signPackCovers } from "@/lib/services/pack-previews";
import { listPacksByCreator } from "@/lib/services/packs";

export const metadata = { title: "Creator" };

export default async function CreatorPage({
  params,
  searchParams,
}: {
  params: Promise<{ handle: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");

  const { handle } = await params;
  const query = await searchParams;
  const cursor = typeof query.cursor === "string" ? query.cursor : undefined;

  const db = await getDatabase();
  let result;
  try {
    result = await listPacksByCreator(db, ownerId, handle, { cursor, limit: 24 });
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  const covers = await signPackCovers(db, ownerId, result.data);

  return (
    <main className="shell creator-page">
      <header className="page-heading">
        <div>
          <div className="eyebrow">Creator</div>
          <h1>{result.creator.isSelf ? "Your packs" : result.creator.displayName}</h1>
          <p className="creator-line">
            @{result.creator.handle} · {result.creator.packCount} {result.creator.packCount === 1 ? "pack" : "packs"}
          </p>
          {result.creator.bio && <p>{result.creator.bio}</p>}
        </div>
      </header>

      {result.data.length === 0 ? (
        <section className="empty-state glass-panel">
          <div className="empty-icon">✦</div>
          <h2>No packs yet</h2>
          <p>{result.creator.isSelf ? "Publish a pack and it will appear here." : "This creator has not published anything yet."}</p>
        </section>
      ) : (
        <PackGrid packs={result.data} previews={covers} />
      )}

      {result.nextCursor && (
        <div className="pagination">
          <Link className="secondary-button" href={`/marketplace/creators/${handle}?cursor=${encodeURIComponent(result.nextCursor)}`}>
            Next page
          </Link>
        </div>
      )}
    </main>
  );
}
