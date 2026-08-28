import sharp from "sharp";
import { loopedTime } from "@/lib/animation/sample";
import type { StickerDocument } from "@/lib/contracts/sticker";
import { frameFragment, IdFactory, type RenderAssets } from "@/lib/render/document-svg";

/**
 * Renders a document to a PNG the agent can look at.
 *
 * A static document draws one frame. An animated one draws a **contact sheet**: several instants
 * across the cycle, laid out in a grid and captioned with their timestamps. A vision model cannot
 * watch a GIF, but it reads a contact sheet the way a person reads a storyboard, and that is enough
 * to answer the questions motion actually raises — has the entrance finished by the time the idle
 * starts, is anything still off-canvas at the end, do two layers arrive on top of each other.
 *
 * Rasterised through `sharp`, which bundles librsvg. The repo already relies on that path for the
 * mock provider's placeholder artwork, so this adds no dependency.
 */

/** Tile size in the contact sheet. Small on purpose — see the note on token cost below. */
const TILE = 224;
const CAPTION = 22;
const COLUMNS = 3;
/**
 * Frames sampled across the cycle.
 *
 * Six is the most that stays useful: the PNG is fed back through the model's context, and a sheet
 * big enough to need scrolling costs more tokens than the extra instants are worth. `estimateTokens`
 * in `lib/ai/compaction` counts a stringified message, so an oversized render would trip compaction
 * and start pruning the very tool calls that record what has already been paid for.
 */
const FRAMES = 6;

const CHECKER = 16;

export type StickerRender = {
  png: Uint8Array;
  /** Instants drawn, in document seconds. One entry for a static document. */
  times: number[];
  width: number;
  height: number;
};

/** Every asset id a render of this document needs. */
export function referencedAssetIds(document: StickerDocument): string[] {
  const ids = new Set<string>();
  if (document.background.type === "image") ids.add(document.background.assetId);
  for (const layer of document.layers) {
    if (layer.type === "image") {
      ids.add(layer.assetId);
      if (layer.maskAssetId) ids.add(layer.maskAssetId);
    }
    if (layer.type === "svg" && layer.source.kind === "asset") ids.add(layer.source.assetId);
  }
  return [...ids];
}

/**
 * The instants a contact sheet samples.
 *
 * Spread across the rendered cycle rather than the authored duration, so a ping-pong document shows
 * its way back as well as its way out. The last sample sits just short of the end: exactly at the
 * end a looping document has already wrapped to t=0, which would waste a tile on a blank frame.
 */
function sampleTimes(document: StickerDocument): number[] {
  if (document.kind === "static") return [0];
  const cycle = document.loop === "pingPong" ? document.durationSeconds * 2 : document.durationSeconds;
  return Array.from({ length: FRAMES }, (_, index) => {
    const wall = (index / FRAMES) * cycle;
    return loopedTime(wall, { durationSeconds: document.durationSeconds, loop: document.loop });
  });
}

/** A light chequerboard, so transparent artwork is visibly transparent rather than looking white. */
function checkerDef(id: string): string {
  return `<pattern id="${id}" width="${CHECKER * 2}" height="${CHECKER * 2}" patternUnits="userSpaceOnUse">`
    + `<rect width="${CHECKER * 2}" height="${CHECKER * 2}" fill="#f2f2f4"/>`
    + `<rect width="${CHECKER}" height="${CHECKER}" fill="#e2e2e6"/>`
    + `<rect x="${CHECKER}" y="${CHECKER}" width="${CHECKER}" height="${CHECKER}" fill="#e2e2e6"/>`
    + `</pattern>`;
}

export function documentSvg(document: StickerDocument, assets: RenderAssets): { svg: string; times: number[]; width: number; height: number } {
  const times = sampleTimes(document);
  const columns = times.length === 1 ? 1 : COLUMNS;
  const rows = Math.ceil(times.length / columns);
  const width = columns * TILE;
  const height = rows * (TILE + CAPTION);

  const ids = new IdFactory();
  const defs: string[] = [checkerDef("checker")];
  const tiles: string[] = [];

  times.forEach((time, index) => {
    const column = index % columns;
    const row = Math.floor(index / columns);
    const x = column * TILE;
    const y = row * (TILE + CAPTION);
    const frame = frameFragment(document, time, TILE, assets, ids);
    defs.push(...frame.defs);
    const caption = document.kind === "static"
      ? "static"
      : `${time.toFixed(2)}s`;
    tiles.push(
      `<g transform="translate(${x},${y})">`
      + `<rect width="${TILE}" height="${TILE}" fill="url(#checker)"/>`
      + `<g>${frame.body}</g>`
      + `<rect y="${TILE}" width="${TILE}" height="${CAPTION}" fill="#1b1b1f"/>`
      + `<text x="${TILE / 2}" y="${TILE + CAPTION / 2}" font-size="12" fill="#f5f5f7" `
      + `text-anchor="middle" dominant-baseline="central" `
      + `font-family="system-ui,Helvetica,Arial,sans-serif">${caption}</text>`
      + `<rect width="${TILE}" height="${TILE + CAPTION}" fill="none" stroke="#000" stroke-opacity="0.18"/>`
      + `</g>`,
    );
  });

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" `
    + `width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`
    + `<defs>${defs.join("")}</defs>`
    + `<rect width="${width}" height="${height}" fill="#1b1b1f"/>`
    + tiles.join("")
    + `</svg>`;

  return { svg, times, width, height };
}

export async function renderSticker(document: StickerDocument, assets: RenderAssets): Promise<StickerRender> {
  const { svg, times, width, height } = documentSvg(document, assets);
  // `density` matters: librsvg rasterises at 72dpi by default, and the SVG's own width/height are in
  // px, so leaving it alone is what keeps the output exactly `width`x`height`.
  const png = await sharp(Buffer.from(svg), { density: 72 })
    .png({ compressionLevel: 9, palette: true })
    .toBuffer();
  return { png: new Uint8Array(png), times, width, height };
}
