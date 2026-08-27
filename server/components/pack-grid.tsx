import Link from "next/link";
import type { PackSummaryV1 } from "@/lib/services/packs";

export type PackPreviewUrls = Map<string, string[]>;

/**
 * The browse card. Covers are a small mosaic of the pack's first members rather than one image,
 * because a pack is a set — a single thumbnail reads as a sticker, not a collection.
 */
export function PackGrid({ packs, previews }: { packs: PackSummaryV1[]; previews: PackPreviewUrls }) {
  return (
    <section className="pack-grid">
      {packs.map((pack) => {
        const urls = previews.get(pack.id) ?? [];
        return (
          <Link className="pack-card glass-panel" href={`/marketplace/${pack.slug}`} key={pack.id}>
            <div className="pack-cover" aria-hidden={urls.length === 0}>
              {urls.length > 0
                ? urls.slice(0, 4).map((url, index) => (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img className="pack-cover-tile" src={url} alt="" key={`${pack.id}-${index}`} />
                ))
                : <span className="pack-cover-empty">✦</span>}
            </div>
            <div className="pack-card-copy">
              <h2>{pack.title}</h2>
              <p className="creator-line">
                by {pack.creator.isSelf ? "you" : pack.creator.displayName}
              </p>
              <p className="pack-card-meta">
                <span className="install-count">{formatInstalls(pack.installCount)}</span>
                <span>· {pack.itemCount} {pack.itemCount === 1 ? "sticker" : "stickers"}</span>
                {pack.installed && <span className="pack-tag">Added</span>}
                {pack.state !== "published" && <span className="pack-tag">{pack.state}</span>}
              </p>
            </div>
          </Link>
        );
      })}
    </section>
  );
}

export function formatInstalls(count: number): string {
  if (count === 0) return "No installs yet";
  return `${count.toLocaleString("en-US")} ${count === 1 ? "install" : "installs"}`;
}
