import Link from "next/link";
import { getHealthyWebSession } from "@/lib/auth/session";

const FAQ = [
  { q: "Do I need to know how to draw?", a: "No. Describe what you want, pick a candidate, and tell the chat what to change. Masking a region or targeting a layer is a tap, not a skill." },
  { q: "What happens to my photos?", a: "Personal photos, prompts, transcripts, and every revision stay private to your account. Nothing is published unless you put it in a pack yourself." },
  { q: "How does the animation work?", a: "Motion is a small, validated JSON scene that renders natively on your device. Preview it live and export GIF or MP4 whenever you want a file." },
  { q: "What is the web library for?", a: "Browsing, comparing revisions, downloading exports, and deleting projects from a bigger screen. Creation stays in the native app." },
  { q: "Can I undo an edit?", a: "Every edit is a new immutable revision. Compare it against its parent, accept it, reject it, or revert to any earlier one." },
  { q: "Can I delete everything?", a: "Yes. Deleting a project starts a durable purge of its records and every private media object. Data remains only until you delete the project." },
];

export default async function Home() {
  const session = await getHealthyWebSession();
  const primaryHref = session?.user ? "/library" : "/login";
  const primaryLabel = session?.user ? "Open your library" : "Sign in with RxLab";

  return (
    <main className="landing">
      {/* Hero: copy on the left, a sample project thread on the right */}
      <header className="hero" id="top">
        <div className="shell">
          <div className="hero-grid">
            <div>
              <div className="eyebrow plain">Sticker Factory for iPhone and iPad</div>
              <h1>Say it with a sticker <span className="hl">you made.</span></h1>
              <p className="hero-copy">
                Describe it, and a transparent sticker appears. Argue with it in a chat until it is right, then
                {" "}<strong>make it move and send it from Messages.</strong>
              </p>
              <div className="hero-actions">
                <Link className="pill-button" href={primaryHref}>{primaryLabel}</Link>
                <a className="secondary-button" href="#how-it-works">How it works</a>
              </div>
              <div className="mini-proof">
                <span>transparent PNG</span><span>animated</span><span>Messages ready</span><span>private</span>
              </div>
            </div>

            <div className="thread" aria-hidden="true">
              <div className="thread-head"><span className="thread-title">Smug cat</span><span className="thread-meta">3 revisions</span></div>
              <div className="thread-msg user">a smug cat, transparent please</div>
              <div className="thread-sticker-row">
                <div className="thread-sticker">🐱</div>
                <span className="state state-candidate">v1 · candidate</span>
              </div>
              <div className="thread-msg user">make it wink and add sunglasses</div>
              <div className="thread-sticker-row">
                <div className="thread-sticker big">😎</div>
                <span className="state state-accepted">v2 · accepted</span>
              </div>
              <div className="thread-msg user">now make the glasses drop in</div>
              <div className="thread-sticker-row">
                <div className="thread-sticker animated">😎</div>
                <span className="state state-motion">v3 · animated</span>
              </div>
              <div className="thread-foot">Sent to Messages as a system sticker</div>
            </div>
          </div>
        </div>
      </header>

      {/* How it works */}
      <section className="band band-sky rounded" id="how-it-works" aria-label="How Sticker Factory works">
        <div className="shell">
          <div className="section-intro">
            <div className="eyebrow">How it works</div>
            <h2>One prompt.<br />One chat. One sticker.</h2>
            <p className="lede">No layers panel and no export wizard. You describe, it draws, you refine, and the result lands in your Stickers drawer.</p>
          </div>
          <div className="feature-grid">
            <article className="card feature-card card-peach">
              <span>01</span>
              <div className="feature-graphic">✍️</div>
              <h3>Generate</h3>
              <p>Use a prompt and optional personal-photo references to create one transparent candidate.</p>
            </article>
            <article className="card feature-card">
              <span>02</span>
              <div className="feature-graphic">💬</div>
              <h3>Refine in chat</h3>
              <p>Edit the whole image, mask a region, target a layer, compare, accept, reject, or revert.</p>
            </article>
            <article className="card feature-card card-lime">
              <span>03</span>
              <div className="feature-graphic">🎞️</div>
              <h3>Animate and share</h3>
              <p>Preview validated motion live, export GIF or MP4, and use the optimized system sticker in Messages.</p>
            </article>
          </div>
        </div>
      </section>

      {/* Revisions */}
      <section className="band band-peach" id="revisions" aria-label="Revisions">
        <div className="shell">
          <div className="section-intro">
            <div className="eyebrow">Every edit is a revision</div>
            <h2>Change your mind.<br />Keep the receipts.</h2>
            <p className="lede">Nothing is overwritten. Each edit becomes a new immutable revision you can compare with its parent, accept, reject, or revert to later.</p>
          </div>
          <div className="revision-strip">
            <article className="card revision-card">
              <div className="thread-sticker">🍞</div>
              <span className="state state-rejected">v1 · rejected</span>
              <p>“a loaf of bread with a face”</p>
            </article>
            <div className="revision-arrow">→</div>
            <article className="card revision-card">
              <div className="thread-sticker">🥐</div>
              <span className="state state-candidate">v2 · candidate</span>
              <p>“make it a croissant, keep the face”</p>
            </article>
            <div className="revision-arrow">→</div>
            <article className="card revision-card card-lime">
              <div className="thread-sticker">🥐</div>
              <span className="state state-accepted">v3 · accepted</span>
              <p>“add a tiny beret”</p>
            </article>
          </div>
        </div>
      </section>

      {/* Motion */}
      <section className="band band-indigo rounded" aria-label="Native animation">
        <div className="shell two">
          <div>
            <div className="eyebrow lime">Motion without video files</div>
            <h2>Animation that is<br />just a scene.</h2>
            <p className="lede">Motion is a small JSON scene, not a baked clip. It renders natively on your device, previews instantly, and becomes a GIF or MP4 only when you ask for one.</p>
          </div>
          <div className="card work-panel">
            <h3>Validated before it renders</h3>
            <p>Every motion snapshot is checked against a schema, so a bad scene never reaches the screen.</p>
            <h3>Live preview</h3>
            <p>Watch the loop on device before you commit to a revision.</p>
            <h3>Export on demand</h3>
            <p>GIF, MP4, animated PNG, and an optimized system sticker for Messages.</p>
          </div>
        </div>
      </section>

      {/* Privacy */}
      <section className="band band-dark" aria-label="Privacy">
        <div className="shell two">
          <div>
            <div className="eyebrow lime">Private by default</div>
            <h2>Your photos are<br />references, not content.</h2>
            <p className="lede">Personal photos, prompts, chat transcripts, and revisions stay private to your account. Nothing is shared unless you publish a pack on purpose.</p>
          </div>
          <div className="card work-panel privacy-card">
            <h3>Private references</h3>
            <p>Photos you upload are only ever used for your own stickers.</p>
            <h3>Immutable revisions</h3>
            <p>Compare, revert, or reject without losing anything.</p>
            <h3>Durable deletion</h3>
            <p>Deleting a project purges its records and every private media object.</p>
          </div>
        </div>
      </section>

      {/* Packs */}
      <section className="band band-lime" id="packs" aria-label="Sticker packs">
        <div className="shell two">
          <div>
            <div className="eyebrow">Packs</div>
            <h2>Bundle them.<br />Share them. Or not.</h2>
            <p className="lede">Publishing is a deliberate choice per pack. Drafts stay yours, unpublishing pulls a pack back, and anyone who adds it gets a new section in their library and in Messages.</p>
            <div className="hero-actions">
              <Link className="secondary-button" href="/marketplace">Browse the marketplace</Link>
            </div>
          </div>
          <div className="pack-sample card">
            <div className="pack-sample-cover">
              <span>🐱</span><span>😎</span><span>🥐</span><span>🍩</span>
            </div>
            <div className="pack-sample-copy">
              <strong>Snack Cats</strong>
              <span>4 stickers · published</span>
            </div>
          </div>
        </div>
      </section>

      {/* FAQ */}
      <section className="band band-paper" id="faq" aria-label="Frequently asked questions">
        <div className="shell">
          <div className="section-intro">
            <div className="eyebrow">Questions</div>
            <h2>Things people ask<br />before their first sticker.</h2>
          </div>
          <div className="faq">
            {FAQ.map((item) => (
              <details key={item.q}>
                <summary>{item.q}</summary>
                <p>{item.a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>

      {/* CTA */}
      <section className="band band-coral rounded" id="get" aria-label="Get started">
        <div className="shell two">
          <div>
            <div className="eyebrow">Ready when you are</div>
            <h2>Your next sticker<br />is one sentence away.</h2>
            <p className="lede lede-on-coral">Create on iPhone or iPad. Sign in here to browse, compare, and download everything you have already made.</p>
          </div>
          <div className="card card-dark price-card">
            <div className="launch-note">
              <b>Sticker Factory</b>
              <span>Create on iOS. Browse, compare, and download on the web.</span>
            </div>
            <ul className="checks">
              <li>Transparent static and animated stickers</li>
              <li>Chat-based refinement with masks and layers</li>
              <li>Native motion with GIF and MP4 export</li>
              <li>Packs you can publish and unpublish</li>
              <li>Private by default, deletable for good</li>
            </ul>
            <Link className="pill-button" href={primaryHref}>{primaryLabel}</Link>
            <p className="fine">Sign-in is handled by RxLab. Sticker Factory never sees your password.</p>
          </div>
        </div>
      </section>
    </main>
  );
}
