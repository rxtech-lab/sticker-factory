import { ImageResponse } from "next/og";
import sharp from "sharp";

export const shareImageSize = { width: 1200, height: 630 };

/** Flatten animated formats and keep unreadable artwork from breaking the sharing card. */
export async function shareThumbnail(url: string | null): Promise<string | null> {
  if (!url) return null;
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(4000), cache: "no-store" });
    if (!response.ok || !response.body) return null;
    const reader = response.body.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 8 * 1024 * 1024) return null;
        chunks.push(value);
      }
    } finally { await reader.cancel(); }
    const png = await sharp(Buffer.concat(chunks), { limitInputPixels: 16_000_000 })
      .resize(260, 260, { fit: "inside" }).png().toBuffer();
    return `data:image/png;base64,${png.toString("base64")}`;
  } catch { return null; }
}

export function shareImage({ title, subtitle, pack = false, thumbnails = [] }: {
  title: string; subtitle: string; pack?: boolean; thumbnails?: (string | null)[];
}) {
  // Put real artwork above the decorative cards, including packs with only one usable preview.
  const artwork = thumbnails.filter((thumbnail): thumbnail is string => Boolean(thumbnail));
  const cards = [null, null, null, ...artwork].slice(-3);
  return new ImageResponse(
    <div style={{ display: "flex", width: "100%", height: "100%", background: "#fff6e9", color: "#30251f", padding: 64, flexDirection: "column", fontFamily: "sans-serif" }}>
      <div style={{ display: "flex", fontSize: 26, fontWeight: 700, color: "#ac481b" }}>STICKER FACTORY / {pack ? "STICKER PACK" : "QUICK MODE"}</div>
      <div style={{ display: "flex", flex: 1, alignItems: "center", gap: 40 }}>
        <div style={{ display: "flex", flexDirection: "column", width: 620 }}>
          <div style={{ display: "flex", fontSize: title.length > 40 ? 52 : 68, fontWeight: 700, lineHeight: 1.08 }}>{title.length > 80 ? `${title.slice(0, 77)}…` : title}</div>
          <div style={{ display: "flex", marginTop: 26, fontSize: 27, lineHeight: 1.35, color: "#756456" }}>{subtitle.length > 110 ? `${subtitle.slice(0, 107)}…` : subtitle}</div>
        </div>
        <div style={{ display: "flex", width: 350, height: 330, position: "relative" }}>
          {cards.map((thumbnail, index) => <div key={index} style={{ display: "flex", position: "absolute", width: 216, height: 216, left: index * 58, top: index === 1 ? 8 : 95, background: ["#fbd977", "#c6d8f7", "#f6bfa4"][index], border: "8px solid white", borderRadius: 42, alignItems: "center", justifyContent: "center", transform: `rotate(${[-14, 4, 16][index]}deg)` }}>
            {thumbnail
              // eslint-disable-next-line @next/next/no-img-element
              ? <img src={thumbnail} alt="" width={190} height={190} style={{ objectFit: "contain" }} />
              : <svg width="130" height="130" viewBox="0 0 130 130"><circle cx="42" cy="48" r="7" fill="#30251f" /><circle cx="88" cy="48" r="7" fill="#30251f" /><path d="M35 77 Q65 111 95 77" stroke="#30251f" strokeWidth="8" fill="none" strokeLinecap="round" /></svg>}
          </div>)}
        </div>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", fontSize: 23, color: "#756456" }}><span>sticker.rxlab.app</span><span>{pack ? "Preview the pack · Get the app" : "5 free generations each day · Sign in to start"}</span></div>
    </div>,
    { ...shareImageSize, headers: { "Cache-Control": "public, max-age=0, s-maxage=300" } },
  );
}
