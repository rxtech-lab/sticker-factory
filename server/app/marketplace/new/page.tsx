import Link from "next/link";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { createPackAction } from "@/app/actions";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { signStickerPreviews } from "@/lib/services/pack-previews";
import { MAX_PACK_ITEMS } from "@/lib/services/packs";
import { listStickers } from "@/lib/services/stickers";

export const metadata = { title: "New pack" };

export default async function NewPackPage() {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");

  const db = await getDatabase();
  // Only published stickers: an unpublished one has no system rendition, so it would be invisible
  // in every surface a pack feeds.
  const eligible = await listStickers(db, ownerId, { status: "published", limit: 100 });
  const previews = await signStickerPreviews(db, ownerId, eligible.data);
  const idempotencyKey = crypto.randomUUID();

  return (
    <main className="shell pack-composer-page">
      <header className="page-heading">
        <div>
          <div className="eyebrow">Marketplace</div>
          <h1>Create a sticker pack</h1>
          <p>Pick from stickers you have already published. You can add more and publish later.</p>
        </div>
        <Link className="secondary-button" href="/marketplace?mine=true">Cancel</Link>
      </header>

      {eligible.data.length === 0 ? (
        <section className="empty-state glass-panel">
          <div className="empty-icon">✦</div>
          <h2>Nothing to bundle yet</h2>
          <p>Publish a sticker in the iOS app first — a pack can only contain published stickers.</p>
        </section>
      ) : (
        <form className="pack-form glass-panel" action={createPackAction}>
          <input type="hidden" name="idempotencyKey" value={idempotencyKey} />

          <label htmlFor="pack-title">Name</label>
          <input id="pack-title" name="title" maxLength={60} required placeholder="Cozy Cats" />

          <label htmlFor="pack-summary">Description</label>
          <input id="pack-summary" name="summary" maxLength={200} placeholder="Twelve cats being extremely comfortable." />

          <fieldset className="checkbox-grid">
            <legend>Stickers (up to {MAX_PACK_ITEMS})</legend>
            {eligible.data.map((sticker) => (
              <label className="checkbox-tile" key={sticker.id}>
                <input type="checkbox" name="stickerIds" value={sticker.id} />
                <span className={`sticker-preview placeholder-${sticker.kind}`}>
                  {previews.get(sticker.id)
                    // eslint-disable-next-line @next/next/no-img-element
                    ? <img src={previews.get(sticker.id)} alt="" />
                    : <span>{sticker.kind === "animated" ? "◌" : "✦"}</span>}
                </span>
                <span className="checkbox-tile-title">{sticker.title}</span>
              </label>
            ))}
          </fieldset>

          <div className="pack-toolbar">
            <button className="pill-button" type="submit">Create pack</button>
          </div>
        </form>
      )}
    </main>
  );
}
