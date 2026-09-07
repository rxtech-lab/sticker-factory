import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { SiteHeader } from "@/components/site-header";

export const metadata: Metadata = {
  title: { default: "Winky - The sticker factory", template: "%s · Winky - The sticker factory" },
  description: "Create static and animated stickers with Winky. Share to WhatsApp, Telegram, and iMessage, or export GIFs and videos.",
  openGraph: {
    type: "website",
    siteName: "Winky - The sticker factory",
    title: "Winky - The sticker factory",
    description: "Say it with a sticker you made. Create, refine, animate, and share from iPhone and iPad.",
  },
  twitter: {
    card: "summary_large_image",
    title: "Winky - The sticker factory",
    description: "Say it with a sticker you made. Create, refine, animate, and share from iPhone and iPad.",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en">
      <body>
        <SiteHeader />
        {children}
        <footer className="site-footer">
          <div className="shell">
            <div className="footer-grid">
              <div className="footer-brand">
                Winky - The sticker factory
                <p>Turn an idea into a sticker that actually moves. Create on iPhone and iPad. Share to WhatsApp, Telegram, and iMessage.</p>
              </div>
              <nav className="footer-links" aria-label="Footer">
                <Link href="/#how-it-works">How it works</Link>
                <Link href="/#revisions">Revisions</Link>
                <Link href="/#faq">Questions</Link>
                <Link href="/library">Your library</Link>
                <Link href="/marketplace">Marketplace</Link>
                <Link href="/about">About</Link>
              </nav>
            </div>
            <div className="footer-bottom">
              <span>© {new Date().getUTCFullYear()} Winky - The sticker factory</span>
              <span>WhatsApp · Telegram · iMessage</span>
            </div>
          </div>
        </footer>
      </body>
    </html>
  );
}
