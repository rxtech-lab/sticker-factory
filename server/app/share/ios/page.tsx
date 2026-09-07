import { APP_STORE_URL, IOS_SHARE_URL, shareMetadata } from "@/lib/sharing";

export const metadata = shareMetadata({
  title: "Make a sticker",
  description: "Turn an idea into a sticker. Sign in and enjoy five free generations every day in the App Clip.",
  url: IOS_SHARE_URL,
  imageAlt: "Your idea. Your sticker. Five free generations each day with Sticker Factory.",
});
export default function QuickSharePage() {
  return <main className="shell"><section className="empty-state glass-panel">
    <div className="eyebrow">Sticker Factory · Quick mode</div>
    <h1>Your idea. Your sticker.</h1>
    <p>Open the App Clip from the banner above, sign in with RxLab, and make a sticker in moments.</p>
    <p>Five free generations each day. Revisions count too. Your stickers stay in your account.</p>
    <a className="pill-button" href={APP_STORE_URL}>Get Sticker Factory</a>
  </section></main>;
}
