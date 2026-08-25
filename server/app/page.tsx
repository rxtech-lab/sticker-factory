import Link from "next/link";
import { getHealthyWebSession } from "@/lib/auth/session";

export default async function Home() {
  const session = await getHealthyWebSession();
  return (
    <main className="shell landing">
      <section className="hero glass-panel">
        <div className="eyebrow">AI stickers, finished by you</div>
        <h1>Turn an idea into a sticker that actually moves.</h1>
        <p className="hero-copy">Create a transparent image, refine it in a private project chat, then animate it with a safe JSON scene that renders natively on your device.</p>
        <div className="hero-actions">
          <Link className="pill-button" href={session?.user ? "/library" : "/login"}>{session?.user ? "Open your library" : "Sign in with RxLab"}</Link>
          <a className="secondary-button" href="#how-it-works">See how it works</a>
        </div>
        <div className="sticker-stage" aria-label="Sticker Factory sample artwork">
          <div className="sample-sticker"><span>hey!</span><span className="sample-face">◕‿◕</span></div>
          <div className="motion-ring ring-one" /><div className="motion-ring ring-two" />
        </div>
      </section>
      <section id="how-it-works" className="feature-grid" aria-label="How Sticker Factory works">
        <article className="glass-panel feature-card"><span>01</span><h2>Generate</h2><p>Use a prompt and optional personal-photo references to create one transparent candidate.</p></article>
        <article className="glass-panel feature-card"><span>02</span><h2>Refine in chat</h2><p>Edit the whole image, mask a region, target a layer, compare, accept, reject, or revert.</p></article>
        <article className="glass-panel feature-card"><span>03</span><h2>Animate and share</h2><p>Preview validated motion snapshots live, export GIF or MP4, and use the optimized system sticker in Messages.</p></article>
      </section>
      <aside className="privacy-card glass-panel">
        <div><strong>Private by default</strong><p>Personal photos, prompts, chat transcripts, and immutable revisions stay private to your account.</p></div>
        <p>Deleting a project starts a durable purge of its Turso records and every private R2 object. Data remains until you delete the project.</p>
      </aside>
    </main>
  );
}
