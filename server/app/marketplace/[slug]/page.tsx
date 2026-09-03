import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { formatInstalls } from "@/components/pack-grid";
import { installPackAction, uninstallPackAction } from "@/app/actions";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { signStickerPreviews } from "@/lib/services/pack-previews";
import { getPack } from "@/lib/services/packs";

export const metadata = { title: "Sticker pack" };

export default async function PackDetailPage({ params }: { params: Promise<{ slug: string }> }) {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");

  const { slug } = await params;
  const db = await getDatabase();
  let pack;
  try {
    pack = await getPack(db, ownerId, slug);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  const previews = await signStickerPreviews(db, ownerId, pack.stickers);
  // One key per render: a double-submitted install collapses to a single effect.
  const idempotencyKey = crypto.randomUUID();

  return (
    <main className="shell pack-detail-page">
      <header className="page-heading">
        <div>
          <div className="eyebrow">Sticker pack</div>
          <h1>{pack.title}</h1>
          {pack.summary && <p>{pack.summary}</p>}
          <p className="creator-line">
            by{" "}
            <Link href={`/marketplace/creators/${pack.creator.handle}`}>
              {pack.creator.isSelf ? "you" : pack.creator.displayName}
            </Link>
            {" · "}
            <span className="install-count">{formatInstalls(pack.installCount)}</span>
            {pack.state !== "published" && <> · <span className="pack-tag">{pack.state}</span></>}
          </p>
        </div>

        <div className="pack-toolbar">
          {pack.isMine ? (
            <>
              <span className="platform-note glass-panel"><strong>Your pack</strong><span>Your stickers are already in your library.</span></span>
              <Link className="secondary-button" href={`/marketplace/${pack.slug}/edit`}>Edit pack</Link>
            </>
          ) : (
            <form action={pack.installed ? uninstallPackAction : installPackAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="slug" value={pack.slug} />
              <input type="hidden" name="idempotencyKey" value={idempotencyKey} />
              <button className={pack.installed ? "secondary-button" : "pill-button"} type="submit">
                {pack.installed ? "Remove from library" : "Add to library"}
              </button>
            </form>
          )}
        </div>
      </header>

      {pack.stickers.length === 0 ? (
        <section className="empty-state glass-panel">
          <div className="empty-icon">✦</div>
          <h2>Nothing published in this pack right now</h2>
          <p>The creator is still working on it. Anything they publish shows up here automatically.</p>
        </section>
      ) : (
        <section className="sticker-grid">
          {pack.stickers.map((sticker) => (
            <article className="sticker-card glass-panel" key={sticker.id}>
              <div className={`sticker-preview placeholder-${sticker.kind}`}>
                {previews.get(sticker.id)
                  // eslint-disable-next-line @next/next/no-img-element
                  ? <img src={previews.get(sticker.id)} alt={`${sticker.title} preview`} />
                  : <span>{sticker.kind === "animated" ? "◌" : "✦"}</span>}
              </div>
              <div className="sticker-card-copy"><div><h2>{sticker.title}</h2><p>{sticker.kind}</p></div></div>
            </article>
          ))}
        </section>
      )}

      <p className="pack-footnote">
        Added packs appear as their own section in your library and in the Messages sticker app.
      </p>
    </main>
  );
}
