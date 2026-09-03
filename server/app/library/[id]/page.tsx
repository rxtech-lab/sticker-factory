import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { deleteStickerAction } from "@/app/actions";
import { FullscreenPreview } from "@/components/fullscreen-preview";
import { StickerDocumentPreview } from "@/components/sticker-document-preview";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { createAssetPreview } from "@/lib/services/assets";
import { getSticker, listChatMessages } from "@/lib/services/stickers";

export const metadata = { title: "Sticker details" };

export default async function StickerDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  await connection();
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");
  const { id } = await params;
  const query = await searchParams;
  const db = await getDatabase();
  let sticker;
  try { sticker = await getSticker(db, ownerId, id); } catch (error) {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  }
  const chatBefore = typeof query.chatBefore === "string" ? Number(query.chatBefore) || undefined : undefined;
  const chat = await listChatMessages(db, ownerId, id, { beforeSequence: chatBefore, latest: !chatBefore, limit: 100 });
  const requestedRevisionId = typeof query.revision === "string" ? query.revision : undefined;
  const selectedRevision = sticker.revisions.find((revision) => revision.id === requestedRevisionId)
    ?? sticker.revisions.find((revision) => revision.id === sticker.activeRevisionId)
    ?? sticker.revisions[0];
  const parentRevision = selectedRevision?.parentRevisionId
    ? sticker.revisions.find((revision) => revision.id === selectedRevision.parentRevisionId)
    : undefined;
  const recentRevisions = [selectedRevision, parentRevision].filter((revision): revision is NonNullable<typeof revision> => Boolean(revision));
  const previewUrls = new Map<string, string>();
  const videoUrls = new Map<string, string>();
  const sceneAssetUrls = new Map<string, Record<string, string>>();
  await Promise.all(recentRevisions.map(async (revision) => {
    if (revision.document.kind === "animated") {
      if (revision.mp4AssetId) {
        try { videoUrls.set(revision.id, (await createAssetPreview(db, ownerId, revision.mp4AssetId)).url); } catch { /* Fall back to the document renderer. */ }
      }
      const urls: Record<string, string> = {};
      await Promise.all(revision.document.layers.flatMap((layer) => layer.type === "image" ? [layer.assetId] : []).map(async (layerAssetId) => {
        try { urls[layerAssetId] = (await createAssetPreview(db, ownerId, layerAssetId)).url; } catch { /* A missing layer is rendered empty. */ }
      }));
      sceneAssetUrls.set(revision.id, urls);
      return;
    }
    const assetId = revision.pngAssetId ?? revision.previewAssetId ?? revision.masterAssetId;
    if (!assetId) return;
    try { previewUrls.set(revision.id, (await createAssetPreview(db, ownerId, assetId)).url); } catch { /* Metadata remains visible if media is temporarily unavailable. */ }
  }));
  const activeRevision = sticker.revisions.find((revision) => revision.id === sticker.activeRevisionId);
  const downloads = activeRevision ? [
    activeRevision.pngAssetId ? { label: "PNG export", assetId: activeRevision.pngAssetId } : activeRevision.masterAssetId ? { label: "Source master", assetId: activeRevision.masterAssetId } : null,
    activeRevision.apngAssetId ? { label: "Animated PNG", assetId: activeRevision.apngAssetId } : null,
    activeRevision.mp4AssetId ? { label: "MP4 video", assetId: activeRevision.mp4AssetId } : null,
    activeRevision.systemAssetId ? { label: "System sticker", assetId: activeRevision.systemAssetId } : null,
  ].filter((item): item is { label: string; assetId: string } => Boolean(item)) : [];
  return (
    <main className="shell detail-page">
      <Link className="back-link" href="/library">← Library</Link>
      <header className="page-heading detail-heading">
        <div><div className="eyebrow">{sticker.kind} sticker</div><h1>{sticker.title}</h1><p>{sticker.status} · {sticker.revisions.length} immutable revision{sticker.revisions.length === 1 ? "" : "s"}</p></div>
        {downloads.length > 0 && <div className="download-row">{downloads.map((item) => <Link className={item.label === "System sticker" ? "pill-button" : "secondary-button"} href={`/download/${item.assetId}`} key={`${item.label}-${item.assetId}`}>{item.label}</Link>)}</div>}
      </header>
      {sticker.revisions.length > 1 && <nav className="revision-picker glass-panel" aria-label="Choose revision to compare"><span>Compare revision</span>{sticker.revisions.map((revision, index) => <Link className={revision.id === selectedRevision?.id ? "active" : ""} href={`/library/${id}?revision=${revision.id}`} key={revision.id}>v{sticker.revisions.length - index} · {revision.candidateState}</Link>)}</nav>}
      <section className="compare-grid" aria-label="Revision comparison">
        {recentRevisions.length === 0 && <div className="empty-state glass-panel"><h2>Generation is in progress</h2><p>The first candidate will appear here after the iOS creation job completes.</p></div>}
        {recentRevisions.map((revision, index) => (
          <article className="revision-preview glass-panel" key={revision.id}>
            <div className="revision-label"><span>{index === 0 ? "Selected" : "Parent"}</span><span className={`state state-${revision.candidateState}`}>{revision.candidateState}</span></div>
            <div className="large-preview">
              {revision.document.kind === "animated" && videoUrls.get(revision.id)
                ? <FullscreenPreview
                    label={`${sticker.title} animated revision`}
                    fullScreenChildren={<video aria-label={`${sticker.title} full-screen animated sticker`} autoPlay controls loop muted playsInline src={videoUrls.get(revision.id)} />}
                  >
                    <video aria-label={`${sticker.title} animated sticker`} autoPlay loop muted playsInline src={videoUrls.get(revision.id)} />
                  </FullscreenPreview>
                : revision.document.kind === "animated"
                ? <FullscreenPreview label={`${sticker.title} animated revision`}>
                    <StickerDocumentPreview document={revision.document} assetUrls={sceneAssetUrls.get(revision.id) ?? {}} label={`${sticker.title} animated revision preview`} repeats />
                  </FullscreenPreview>
                : previewUrls.get(revision.id)
                // Private five-minute R2 URL generated only after ownership verification.
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={previewUrls.get(revision.id)} alt={`${sticker.title} revision preview`} />
                : <span>Preview unavailable</span>}
            </div>
            <details><summary>StickerDocument</summary><pre>{JSON.stringify(revision.document, null, 2)}</pre></details>
          </article>
        ))}
      </section>
      <section className="detail-columns">
        <article className="chat-history glass-panel">
          <div className="section-title"><div><div className="eyebrow">Read-only</div><h2>Project chat</h2></div><span>{chat.data.length} messages</span></div>
          <ol>{chat.data.map((message) => <li className={`chat-${message.role}${message.role === "system" && message.kind === "status" ? " chat-tool" : ""}`} key={message.id}><div><strong>{message.role === "user" ? "You" : message.role === "assistant" ? "Sticker Factory" : message.kind === "status" ? "Tool call" : "System"}</strong><time>{new Date(message.createdAt).toLocaleString()}</time></div><p>{message.content}</p>{message.role === "system" && message.kind === "status" && <small>{message.status === "streaming" ? "Running…" : message.status === "failed" ? "Stopped or failed" : "Completed"}</small>}{message.attachments.length > 0 && <small>{message.attachments.length} private attachment{message.attachments.length === 1 ? "" : "s"}</small>}</li>)}</ol>
          {chat.nextBeforeSequence && <Link className="secondary-button older-chat" href={`/library/${id}?${new URLSearchParams({ ...(selectedRevision ? { revision: selectedRevision.id } : {}), chatBefore: String(chat.nextBeforeSequence) }).toString()}`}>Older messages</Link>}
        </article>
        <aside className="project-settings glass-panel">
          <div className="eyebrow">Project</div><h2>Privacy & deletion</h2><p>Sources, masks, transcript, generated assets, and revisions remain private until this project is deleted.</p>
          <form action={deleteStickerAction}><input type="hidden" name="stickerId" value={sticker.id} /><input type="hidden" name="idempotencyKey" value={`web-delete:${sticker.id}:${crypto.randomUUID()}`} /><button className="danger-button" type="submit">Delete project and media</button></form>
        </aside>
      </section>
    </main>
  );
}
