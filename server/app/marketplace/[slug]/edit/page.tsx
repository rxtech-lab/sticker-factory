import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import {
  addPackItemAction,
  deletePackAction,
  movePackItemAction,
  publishPackAction,
  removePackItemAction,
  unpublishPackAction,
  updatePackAction,
} from "@/app/actions";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { signStickerPreviews } from "@/lib/services/pack-previews";
import { MAX_PACK_ITEMS, getPack, listHiddenPackMembers } from "@/lib/services/packs";
import { listStickers } from "@/lib/services/stickers";

export const metadata = { title: "Edit pack" };

export default async function EditPackPage({ params }: { params: Promise<{ slug: string }> }) {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");

  const { slug } = await params;
  const db = getDatabase();
  let pack;
  try {
    pack = await getPack(db, ownerId, slug);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  if (!pack.isMine) notFound();

  const [hidden, eligible] = await Promise.all([
    listHiddenPackMembers(db, ownerId, pack.id),
    listStickers(db, ownerId, { status: "published", limit: 100 }),
  ]);
  const memberIds = new Set(pack.stickers.map((sticker) => sticker.id));
  const addable = eligible.data.filter((sticker) => !memberIds.has(sticker.id));
  const previews = await signStickerPreviews(db, ownerId, [...pack.stickers, ...addable]);
  const key = () => crypto.randomUUID();

  return (
    <main className="shell pack-composer-page">
      <header className="page-heading">
        <div>
          <div className="eyebrow">Editing · {pack.state}</div>
          <h1>{pack.title}</h1>
          <p>{pack.installCount.toLocaleString("en-US")} installs · {pack.stickers.length} visible stickers</p>
        </div>
        <div className="pack-toolbar">
          <Link className="secondary-button" href={`/marketplace/${pack.slug}`}>View pack</Link>
          {pack.state === "published" ? (
            <form action={unpublishPackAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="state" value="draft" />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="secondary-button" type="submit">Unpublish</button>
            </form>
          ) : (
            <form action={publishPackAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="pill-button" type="submit" disabled={pack.stickers.length === 0}>Publish</button>
            </form>
          )}
        </div>
      </header>

      {/*
        A device edit silently drops a published sticker back to draft, at which point it vanishes
        from every installer's copy of the pack. Nobody would otherwise ever be told.
      */}
      {hidden.length > 0 && (
        <section className="pack-warning glass-panel">
          <strong>
            {hidden.length} {hidden.length === 1 ? "sticker is" : "stickers are"} hidden from people who added this pack
          </strong>
          <p>Editing a sticker on device returns it to draft. Publish it again in the iOS app to bring it back.</p>
          <ul>{hidden.map((sticker) => <li key={sticker.id}>{sticker.title} — {sticker.status}</li>)}</ul>
        </section>
      )}

      <form className="pack-form glass-panel" action={updatePackAction}>
        <input type="hidden" name="packId" value={pack.id} />
        <input type="hidden" name="idempotencyKey" value={key()} />
        <label htmlFor="pack-title">Name</label>
        <input id="pack-title" name="title" maxLength={60} required defaultValue={pack.title} />
        <label htmlFor="pack-summary">Description</label>
        <input id="pack-summary" name="summary" maxLength={200} defaultValue={pack.summary ?? ""} />
        <p className="pack-footnote">The link stays <code>/marketplace/{pack.slug}</code> even if you rename the pack.</p>
        <div className="pack-toolbar"><button className="secondary-button" type="submit">Save details</button></div>
      </form>

      <section className="glass-panel pack-members">
        <h2>In this pack ({pack.stickers.length}/{MAX_PACK_ITEMS})</h2>
        {pack.stickers.length === 0 ? (
          <p>Nothing here yet. Add a published sticker below.</p>
        ) : pack.stickers.map((sticker, index) => (
          <div className="pack-item-row" key={sticker.id}>
            <span className={`sticker-preview placeholder-${sticker.kind}`}>
              {previews.get(sticker.id)
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={previews.get(sticker.id)} alt="" />
                : <span>{sticker.kind === "animated" ? "◌" : "✦"}</span>}
            </span>
            <span className="pack-item-title">{sticker.title}</span>
            <form action={movePackItemAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="stickerId" value={sticker.id} />
              <input type="hidden" name="direction" value="up" />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="secondary-button" type="submit" disabled={index === 0} aria-label={`Move ${sticker.title} up`}>↑</button>
            </form>
            <form action={movePackItemAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="stickerId" value={sticker.id} />
              <input type="hidden" name="direction" value="down" />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="secondary-button" type="submit" disabled={index === pack.stickers.length - 1} aria-label={`Move ${sticker.title} down`}>↓</button>
            </form>
            <form action={removePackItemAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="stickerId" value={sticker.id} />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="danger-button" type="submit">Remove</button>
            </form>
          </div>
        ))}
      </section>

      <section className="glass-panel pack-members">
        <h2>Add a sticker</h2>
        {addable.length === 0 ? (
          <p>Every published sticker you own is already in this pack.</p>
        ) : addable.map((sticker) => (
          <div className="pack-item-row" key={sticker.id}>
            <span className={`sticker-preview placeholder-${sticker.kind}`}>
              {previews.get(sticker.id)
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={previews.get(sticker.id)} alt="" />
                : <span>{sticker.kind === "animated" ? "◌" : "✦"}</span>}
            </span>
            <span className="pack-item-title">{sticker.title}</span>
            <form action={addPackItemAction}>
              <input type="hidden" name="packId" value={pack.id} />
              <input type="hidden" name="stickerId" value={sticker.id} />
              <input type="hidden" name="idempotencyKey" value={key()} />
              <button className="secondary-button" type="submit" disabled={pack.stickers.length >= MAX_PACK_ITEMS}>Add</button>
            </form>
          </div>
        ))}
      </section>

      <form className="pack-danger-zone" action={deletePackAction}>
        <input type="hidden" name="packId" value={pack.id} />
        <input type="hidden" name="idempotencyKey" value={key()} />
        <button className="danger-button" type="submit">Delete this pack</button>
        <span>Removes it from the marketplace and from everyone who added it. Your stickers are untouched.</span>
      </form>
    </main>
  );
}
