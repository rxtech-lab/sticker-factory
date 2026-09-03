import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { SiteHeader } from "@/components/site-header";

export const metadata: Metadata = {
  title: { default: "Sticker Factory", template: "%s · Sticker Factory" },
  description: "Your private library for AI-created static and animated stickers.",
  openGraph: {
    type: "website",
    siteName: "Sticker Factory",
    title: "Sticker Factory",
    description: "Say it with a sticker you made. Create, refine, animate, and share from iPhone and iPad.",
  },
  twitter: {
    card: "summary_large_image",
    title: "Sticker Factory",
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
                Sticker Factory
                <p>Turn an idea into a sticker that actually moves. Private by default, native on iPhone, iPad, and Messages.</p>
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
              <span>© {new Date().getUTCFullYear()} Sticker Factory</span>
              <span>iPhone · iPad · Messages · Stickers drawer</span>
            </div>
          </div>
        </footer>
      </body>
    </html>
  );
}
