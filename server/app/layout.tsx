import type { Metadata } from "next";
import "./globals.css";
import { SiteHeader } from "@/components/site-header";

export const metadata: Metadata = {
  title: { default: "Sticker Factory", template: "%s · Sticker Factory" },
  description: "Your private library for AI-created static and animated stickers.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en">
      <body>
        <div className="ambient ambient-one" aria-hidden="true" />
        <div className="ambient ambient-two" aria-hidden="true" />
        <SiteHeader />
        {children}
        <footer>Made for iPhone, iPad, Messages, and the system Stickers drawer.</footer>
      </body>
    </html>
  );
}
