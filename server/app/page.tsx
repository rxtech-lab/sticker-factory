import Image from "next/image";
import Link from "next/link";
import { getHealthyWebSession } from "@/lib/auth/session";
import "./home.css";

const FAQ = [
  { q: "Do I need to know how to draw?", a: "No. Start with an idea or a photo, then tell Winky what to change. Try a different expression, add a tiny hat, or make your character move. Your imagination does the directing." },
  { q: "Where can I use my stickers?", a: "Share sticker packs to WhatsApp and Telegram, or use your stickers in iMessage. Winky prepares the formats for each app and guides you through adding a pack." },
  { q: "Can I make animated stickers and videos?", a: "Yes. Bring your sticker to life, preview the motion, and export animated stickers, GIFs, or MP4 videos. Save a transparent PNG when you want to keep things still." },
  { q: "What happens to my photos?", a: "Your photo references, prompts, and edits stay private to your account. A sticker pack is only published when you choose to share it." },
  { q: "Can I undo an edit?", a: "Absolutely. Each edit saves a new version. Compare your ideas, keep your favorite, or go back to an earlier version whenever you change your mind." },
  { q: "What is the web library for?", a: "Create on iPhone and iPad. Use the web library to browse your stickers, compare versions, download exports, and delete projects from a bigger screen." },
];

function Art({ name, alt = "", className = "", preload = false }: { name: string; alt?: string; className?: string; preload?: boolean }) {
  const extension = name.startsWith("winky") ? "svg" : "webp";
  return <Image className={`winky-art ${className}`} src={`/images/home/${name}.${extension}`} alt={alt} width={512} height={512} preload={preload} unoptimized />;
}

function AnimatedWinky({ alt, className = "", preload = false }: { alt: string; className?: string; preload?: boolean }) {
  return (
    <div className={`winky-animated ${className}`} role="img" aria-label={alt}>
      <Art name="winky" preload={preload} />
      <Art name="winky-wink" className="winky-wink-frame" preload={preload} />
    </div>
  );
}

export default async function Home() {
  const session = await getHealthyWebSession();
  const primaryHref = session?.user ? "/library" : "/login";
  const primaryLabel = session?.user ? "Open your library" : "Sign in to your library";
  const appStoreUrl = process.env.APP_STORE_URL?.trim();

  return (
    <main className="landing winky-home">
      <div className="reading-progress" aria-hidden="true" />
      <header className="hero" id="top">
        <div className="shell hero-grid">
          <div className="winky-hero-copy">
            <div className="eyebrow plain">Winky - The sticker factory</div>
            <h1>Big feelings.<br />Tiny <span className="hl">stickers.</span></h1>
            <p className="hero-copy">That inside joke. Your pet’s attitude. Your very specific mood. Turn it into a sticker with Winky, then <strong>make it move.</strong></p>
            <div className="hero-actions">
              <Link className="pill-button" href={primaryHref}>{primaryLabel}</Link>
              <a className="secondary-button" href="#how-it-works">Meet your sticker maker <span aria-hidden="true">↗</span></a>
            </div>
            {appStoreUrl && (
              <a className="winky-app-store-badge" href={appStoreUrl}>
                <Image src="/images/home/download-on-the-app-store.svg" alt="Download on the App Store" width={180} height={60} unoptimized />
              </a>
            )}
            <p className="winky-device-note">Made on iPhone &amp; iPad. Shared everywhere you chat.</p>
            <div className="platform-pills" aria-label="Supported messaging apps"><span>WhatsApp</span><span>Telegram</span><span>iMessage</span></div>
          </div>
          <div className="winky-studio" aria-label="Illustrated example of making a Winky sticker">
            <div className="studio-top"><span>A LITTLE IDEA, A LOT OF PERSONALITY</span><span aria-hidden="true">↗</span></div>
            <div className="studio-prompt">“Winky, but with main character energy.”</div>
            <div className="studio-art"><AnimatedWinky alt="Winky blinking and winking with little stars" preload /><span className="studio-stamp">100%<br />your vibe</span><Art name="winky" className="studio-sidekick" /></div>
            <div className="studio-caption"><span className="state state-accepted">Made with Winky</span><span>Still. Silly. Or in motion.</span></div>
          </div>
        </div>
      </header>

      <div className="winky-format-strip" aria-label="Creative formats"><span>Static stickers</span><i aria-hidden="true" /><span>Animated stickers</span><i aria-hidden="true" /><span>GIFs</span><i aria-hidden="true" /><span>Videos</span><i aria-hidden="true" /><span>Sticker packs</span></div>

      <section className="band band-sky rounded" id="how-it-works" aria-label="How Winky works">
        <div className="shell">
          <div className="section-intro scroll-reveal"><div className="eyebrow">From “what if” to “send”</div><h2>You bring the idea.<br />Winky brings it to life.</h2><p className="lede">A little imagination is all it takes. No drawing skills required.</p></div>
          <div className="feature-grid">
            {[
              { art: "pencil", title: "Dream it up", text: "Describe your idea or start with a photo. A pet, a friend, a snack with feelings. Anything goes.", color: "card-peach" },
              { art: "chat", title: "Make it yours", text: "Keep the conversation going. Change the colors, try a new expression, or add that one perfect detail.", color: "" },
              { art: "movie", title: "Give it a little life", text: "Make it wiggle, wink, or wave. Preview your animation, then share a sticker, GIF, or video.", color: "card-lime" },
            ].map((step, index) => <article key={step.art} className={`card feature-card scroll-reveal ${step.color}`}><span>0{index + 1}</span><Art name={step.art} /><h3>{step.title}</h3><p>{step.text}</p></article>)}
          </div>
        </div>
      </section>

      <section className="band winky-sharing" aria-label="Supported apps and export formats">
        <div className="shell">
          <div className="section-intro scroll-reveal"><div className="eyebrow">Good stickers travel</div><h2>Made by you.<br />Sent to your people.</h2><p className="lede">From the group chat to your favorite person. Your creations belong in the conversations you love.</p></div>
          <div className="sharing-grid">
            <article className="card share-card whatsapp scroll-reveal"><span className="share-number">01 / GROUP CHAT ENERGY</span><h3>WhatsApp</h3><p>Turn your creations into static or animated sticker packs and add them to WhatsApp.</p><span className="share-tag">Static + animated packs</span></article>
            <article className="card share-card telegram scroll-reveal"><span className="share-number">02 / SEND SOMETHING EXTRA</span><h3>Telegram</h3><p>Take your characters to Telegram with static stickers and moving video stickers.</p><span className="share-tag">Static + video stickers</span></article>
            <article className="card share-card imessage scroll-reveal"><span className="share-number">03 / A MORE PERSONAL REPLY</span><h3>iMessage</h3><p>Keep your favorites in Messages, ready to send as still or animated stickers.</p><span className="share-tag">Static + animated stickers</span></article>
          </div>
          <div className="export-note"><strong>Want a file instead?</strong><span>Export transparent PNG, animated PNG, GIF, or MP4 video. Save it, post it, or share it your way.</span></div>
        </div>
      </section>

      <section className="band band-indigo rounded" aria-label="Animated stickers and video">
        <div className="shell two">
          <div className="scroll-reveal"><div className="eyebrow lime">A little motion. A lot of mood.</div><h2>Why just smile<br />when you can <em>wink?</em></h2><p className="lede">Give your character a signature move. Preview the loop, fine-tune the feeling, and take it from animated sticker to shareable video.</p><div className="motion-formats"><span>Animated stickers</span><span>GIF</span><span>MP4 video</span></div></div>
          <div className="motion-stage"><span className="motion-stage-label">YOUR NEXT REACTION</span><div className="motion-loop"><AnimatedWinky className="scroll-wiggle" alt="Winky blinking and winking as an animated reaction" /></div><span className="motion-stage-foot">Small sticker. Big main-character energy.</span></div>
        </div>
      </section>

      <section className="band band-peach" id="revisions" aria-label="Creative revisions">
        <div className="shell two"><div className="revision-art scroll-reveal"><Art name="winky" alt="Original Winky sticker" /><span aria-hidden="true">↗</span><Art name="winky-wink" alt="Winky sticker revised with a wink and stars" /></div><div className="scroll-reveal"><div className="eyebrow">Room to change your mind</div><h2>A little more this.<br />A little less that.</h2><p className="lede">Every edit gets its own version. Compare your ideas, keep the one you love, or go back to an earlier favorite. Experiment freely.</p></div></div>
      </section>

      <section className="band band-lime" id="packs" aria-label="Sticker packs">
        <div className="shell two"><div className="scroll-reveal"><div className="eyebrow">Better together</div><h2>Your own little<br />cast of characters.</h2><p className="lede">Build a pack around a mood, a friend, or an inside joke. Keep it just for you, or publish it for others to discover.</p><div className="hero-actions"><Link className="secondary-button" href="/marketplace">Explore sticker packs <span aria-hidden="true">↗</span></Link></div></div><div className="pack-sample card scroll-reveal"><div className="pack-sample-cover"><Image className="pack-sample-collage" src="/images/home/winky-sticker-collage.webp" alt="A collection of Winky stickers with hearts, stars, and sweets" width={900} height={600} /></div><div className="pack-sample-copy"><strong>The personality pack</strong><span>A little collection of big moods</span></div></div></div>
      </section>

      <section className="band band-paper" id="faq" aria-label="Frequently asked questions">
        <div className="shell"><div className="section-intro"><div className="eyebrow">Questions</div><h2>A few things<br />before your first wink.</h2><p className="lede">Big ideas welcome. Little questions, too.</p></div><div className="faq">{FAQ.map((item) => <details key={item.q}><summary>{item.q}</summary><div className="faq-answer"><p>{item.a}</p></div></details>)}</div></div>
      </section>

      <section className="band band-coral rounded" id="get" aria-label="Get started with Winky"><div className="shell two"><div className="scroll-reveal"><div className="eyebrow">Winky - The sticker factory</div><h2>The group chat<br />is waiting.</h2><p className="lede lede-on-coral">Create on iPhone and iPad. Open your web library to browse your stickers, revisit your favorites, and download your exports.</p></div><div className="card card-dark price-card"><div className="launch-note"><b>A whole lot of you. In a sticker.</b><span>Private by default. Shared when you choose.</span></div><ul className="checks"><li>Static and animated stickers</li><li>WhatsApp, Telegram, and iMessage</li><li>GIF, transparent PNG, and video exports</li><li>Your ideas, your photos, your own style</li></ul><Link className="pill-button" href={primaryHref}>{primaryLabel}</Link><p className="fine">Secure sign-in with RxLab.</p></div></div></section>
    </main>
  );
}
