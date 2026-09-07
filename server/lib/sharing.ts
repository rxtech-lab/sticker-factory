import type { Metadata } from "next";

export const APP_STORE_ID = "6805825708";
export const APP_STORE_URL = `https://apps.apple.com/app/id${APP_STORE_ID}`;
export const IOS_SHARE_URL = "https://sticker.rxlab.app/share/ios";
export const APP_CLIP_BUNDLE_ID = "app.rxlab.stickerfactory.Clip";
export const APP_CLIP_BANNER = `app-id=${APP_STORE_ID}, app-clip-bundle-id=${APP_CLIP_BUNDLE_ID}, app-clip-display=card`;
export function packShareURL(slug: string) { return `${IOS_SHARE_URL}/packs/${encodeURIComponent(slug)}`; }

/** Both marketplace and iOS shares land on these public, crawler-accessible pages. */
export function shareMetadata({ title, description, url, imageAlt }: {
  title: string;
  description: string;
  url: string;
  imageAlt: string;
}): Metadata {
  const image = { url: `${url}/opengraph-image`, width: 1200, height: 630, alt: imageAlt, type: "image/png" };
  return {
    metadataBase: new URL(IOS_SHARE_URL),
    title,
    description,
    alternates: { canonical: url },
    other: { "apple-itunes-app": APP_CLIP_BANNER },
    openGraph: { type: "website", siteName: "Sticker Factory", title, description, url, images: [image] },
    twitter: { card: "summary_large_image", title, description, images: [image] },
  };
}
