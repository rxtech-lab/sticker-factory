import sharp from "sharp";
import { loopedTime, sequenceFrameIndex } from "@/lib/animation/sample";
import { layerImageAssetIds, type StickerDocument } from "@/lib/contracts/sticker";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { frameFragment, IdFactory, sequenceCellKey, type RenderAssets } from "@/lib/render/document-svg";

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
  bytes: Uint8Array;
  /** Always `SHEET_MIME`. Carried explicitly so callers never hard-code the encoding. */
  mimeType: string;
  /** Instants drawn, in document seconds. One entry for a static document. */
  times: number[];
  width: number;
  height: number;
};

/**
 * The encoding the sheet is handed back in.
 *
 * WebP rather than PNG: the sheet is fed straight into the model's context, where `estimateTokens`
 * stringifies it, so its byte size is a running cost paid on every single `view_sticker` call. At
 * this quality it is several times smaller than the palette PNG it replaces and the difference is
 * invisible on a 224px tile — and the tiles are drawn over an opaque chequerboard, so the alpha
 * PNG was carrying is not information the agent loses.
 *
 * **Only the finished sheet.** Assets inlined *into* the SVG must stay PNG: the librsvg inside
 * `sharp` does not decode an embedded WebP `data:` URI and, worse, does not error on one — it
 * draws nothing at all, which would hand the agent a blank tile it has no way to distinguish from
 * a genuinely empty layer.
 */
export const SHEET_MIME = "image/webp";
const SHEET_QUALITY = 72;

/** Every asset id a render of this document needs. */
export function referencedAssetIds(document: StickerDocument): string[] {
  const ids = new Set<string>();
  if (document.background.type === "image") ids.add(document.background.assetId);
  for (const layer of document.layers) {
    for (const id of layerImageAssetIds(layer)) ids.add(id);
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

/**
 * The longest edge worth keeping for a bitmap that ends up inside one tile.
 *
 * Twice the tile, so a layer scaled up past 1 still has pixels to show rather than going soft.
 */
const ASSET_EDGE = TILE * 2;

/**
 * The longest edge of one atlas cell.
 *
 * Tighter than `ASSET_EDGE` because a cell's situation is known exactly rather than bounded: it is
 * drawn into `LAYER_FIT * TILE` — about 193px — of a single tile, and there are up to six of them
 * inlined in one sheet, so this is the number that decides how big the markup gets. `ASSET_EDGE`'s
 * doubling buys headroom for a layer scaled past 1; at 224 a cell still has more pixels than the
 * box it lands in, and the sheet is a review render where the tool description already tells the
 * agent not to judge fine detail.
 */
const CELL_EDGE = TILE;

/** How large each raster can usefully be, by asset id. Anything absent is left alone. */
function assetEdges(document: StickerDocument, edge: number): Map<string, number> {
  const edges = new Map<string, number>();
  const want = (id: string, value: number) => edges.set(id, Math.max(edges.get(id) ?? 0, value));
  if (document.background.type === "image") want(document.background.assetId, edge);
  for (const layer of document.layers) {
    // A sequence layer's atlas is handled by `sliceAtlases`, which replaces it with the individual
    // cells — so it is deliberately not listed here and never inlined whole.
    if (layer.type === "sequence") continue;
    for (const id of layerImageAssetIds(layer)) want(id, edge);
  }
  return edges;
}

/**
 * Which cells of which atlas the sheet actually draws.
 *
 * At most one per sampled instant per sequence layer — six for an animated document, one for a
 * static one — however many frames the capture holds. Deduplicated because a short capture on a
 * long timeline shows the same frame in more than one tile.
 */
function requiredCells(document: StickerDocument, times: number[]): Map<string, Set<number>> {
  const cells = new Map<string, Set<number>>();
  for (const layer of document.layers) {
    if (layer.type !== "sequence") continue;
    const indices = cells.get(layer.assetId) ?? new Set<number>();
    for (const time of times) indices.add(sequenceFrameIndex(layer, time));
    cells.set(layer.assetId, indices);
  }
  return cells;
}

/**
 * Cuts each frame atlas down to the cells the sheet draws, and drops the atlas itself.
 *
 * This is the whole reason `view_sticker` can look at a capture at all. The atlas is one asset —
 * up to 64 tiles at 640px, which the iOS encoder only stops growing at 20 MB — and the previous
 * implementation inlined it as a base64 `data:` URI *once per tile*, so a six-frame contact sheet
 * carried six copies of every frame to show six of them. libxml2 caps a single attribute at 10 MB
 * (`XML_MAX_HUGE_LENGTH`), which is what `view_sticker` used to die on, and even under that ceiling
 * the markup ran to tens of megabytes.
 *
 * Cells are cut with `extract` on integer cell dimensions — the same floor division the renderer
 * and `ensureAtlasPoster` use — so the cell the agent reviews is the cell a playing client shows.
 *
 * Best-effort per atlas: a failure leaves the atlas out entirely rather than falling back to
 * inlining it whole, because inlining it whole is the failure being fixed. `document-svg` then
 * draws its labelled "capture" placeholder, which is a worse render but still a render.
 */
async function sliceAtlases(
  document: StickerDocument,
  assets: RenderAssets,
  times: number[],
  into: RenderAssets,
  cellEdge: number,
): Promise<void> {
  await Promise.all([...requiredCells(document, times)].map(async ([assetId, indices]) => {
    const atlas = assets.get(assetId);
    if (!atlas) return;
    const layer = document.layers.find(
      (candidate) => candidate.type === "sequence" && candidate.assetId === assetId,
    );
    if (layer?.type !== "sequence") return;
    try {
      const source = sharp(atlas.bytes);
      const { width = 0, height = 0 } = await source.metadata();
      const cellWidth = Math.floor(width / layer.columns);
      const cellHeight = Math.floor(height / layer.rows);
      if (cellWidth < 1 || cellHeight < 1) throw new Error(`atlas is ${width}x${height}`);
      await Promise.all([...indices].map(async (index) => {
        const bytes = await sharp(atlas.bytes)
          .extract({
            left: (index % layer.columns) * cellWidth,
            top: Math.floor(index / layer.columns) * cellHeight,
            width: cellWidth,
            height: cellHeight,
          })
          // PNG, not WebP: see the note on `SHEET_MIME`. Alpha is load-bearing here — the cell is a
          // cut-out subject, and a white box behind it would read as a lift failure.
          .resize(cellEdge, cellEdge, { fit: "inside", withoutEnlargement: true })
          .png({ compressionLevel: 9 })
          .toBuffer();
        into.set(sequenceCellKey(assetId, index), { bytes: new Uint8Array(bytes), mimeType: "image/png" });
      }));
      traceEvent("render:atlas:sliced", {
        assetId,
        atlasBytes: atlas.bytes.byteLength,
        grid: `${layer.columns}x${layer.rows}`,
        cells: indices.size,
        cellBytes: [...indices].reduce(
          (total, index) => total + (into.get(sequenceCellKey(assetId, index))?.bytes.byteLength ?? 0),
          0,
        ),
      });
    } catch (error) {
      traceEvent("render:atlas:fail", {
        assetId,
        atlasBytes: atlas.bytes.byteLength,
        grid: `${layer.columns}x${layer.rows}`,
        error: describeError(error),
      });
    }
  }));
}

/**
 * Shrinks every bitmap to the size the sheet can actually show it at.
 *
 * Not an optimisation — a correctness fix. Each raster is inlined as a base64 `data:` URI, once per
 * tile, and libxml2 refuses any single attribute over 10 MB (`XML_MAX_HUGE_LENGTH`), so `sharp`
 * rejects the whole SVG with "Buffer size limit exceeded, try XML_PARSE_HUGE" and `view_sticker`
 * fails. A capture atlas walks straight into that: the iOS encoder packs up to 64 tiles at 640px
 * and only gives up at 20 MB, which is 27 MB of base64 — so every animated sticker built from a
 * Live Photo lost the one tool the agent has for looking at its own work.
 *
 * Failures drop the asset instead of passing the original through: the renderer draws a labelled
 * placeholder for a missing bitmap, which is a worse render but still a render, whereas keeping an
 * oversized one would fail the whole call again for the same reason.
 */
export async function prepareSheetAssets(
  document: StickerDocument,
  assets: RenderAssets,
): Promise<RenderAssets> {
  // `sampleTimes` is pure and deterministic, so deciding which atlas cells are needed here and
  // drawing them in `documentSvg` cannot disagree about which instants the sheet shows.
  return prepareRenderAssets(document, assets, {
    times: sampleTimes(document),
    assetEdge: ASSET_EDGE,
    cellEdge: CELL_EDGE,
  });
}

/**
 * The general form of the above: fit every bitmap for a render of `times` at a known box size.
 *
 * A publishable rendition (`lib/render/renditions.ts`) draws the same document through the same
 * SVG renderer, but one instant per image at up to 1024px rather than six at 224px — so it needs
 * the same atlas slicing and the same oversize guard with entirely different numbers. Sharing the
 * body rather than copying it is what keeps the contact sheet and the published sticker showing
 * the same pixels.
 */
export async function prepareRenderAssets(
  document: StickerDocument,
  assets: RenderAssets,
  options: { times: number[]; assetEdge: number; cellEdge: number },
): Promise<RenderAssets> {
  const { times, assetEdge, cellEdge } = options;
  const edges = assetEdges(document, assetEdge);
  const fitted: RenderAssets = new Map();
  const atlases = requiredCells(document, times);
  await Promise.all([...assets].map(async ([id, asset]) => {
    // Replaced by its own cells below, and deliberately not copied across: leaving it in the map
    // would let `document-svg`'s whole-atlas fallback inline it again.
    if (atlases.has(id)) return;
    const edge = edges.get(id);
    // Not a bitmap this renderer rasterises — an SVG layer's source is embedded as markup.
    if (edge === undefined) {
      fitted.set(id, asset);
      traceEvent("render:asset:passthrough", { assetId: id, bytes: asset.bytes.byteLength, mimeType: asset.mimeType });
      return;
    }
    try {
      const bytes = await sharp(asset.bytes)
        .resize(edge, edge, { fit: "inside", withoutEnlargement: true })
        .png({ compressionLevel: 9 })
        .toBuffer();
      fitted.set(id, { bytes: new Uint8Array(bytes), mimeType: "image/png" });
      traceEvent("render:asset:fit", {
        assetId: id,
        edge,
        // Both sizes, because the inlined `data:` URI is ~4/3 of the *after* number and the 10 MB
        // libxml2 attribute ceiling is the thing this whole function exists to stay under.
        beforeBytes: asset.bytes.byteLength,
        afterBytes: bytes.byteLength,
      });
    } catch (error) {
      // Dropped on purpose; see above. Logged because the render that follows is then quietly a
      // placeholder, and a sheet full of purple boxes is indistinguishable from a layout bug.
      traceEvent("render:asset:fail", {
        assetId: id,
        edge,
        bytes: asset.bytes.byteLength,
        mimeType: asset.mimeType,
        error: describeError(error),
      });
    }
  }));
  await sliceAtlases(document, assets, times, fitted, cellEdge);
  return fitted;
}

/**
 * What the markup looks like from libxml2's side, for a failure line.
 *
 * Computed only when the rasterise throws: `href` is matched across a string that can be tens of
 * megabytes, which is not worth doing on the happy path. `largestHrefBytes` is the number that
 * matters — libxml2 caps a *single attribute* at 10 MB (`XML_MAX_HUGE_LENGTH`), so a sheet can be
 * far past that in total and still parse, while one oversized atlas fails the whole document.
 */
function svgDiagnostics(svg: string): Record<string, number> {
  let largest = 0;
  let count = 0;
  for (const match of svg.matchAll(/(?:xlink:)?href="data:[^"]*"/g)) {
    count += 1;
    largest = Math.max(largest, match[0].length);
  }
  return { svgBytes: svg.length, inlinedCount: count, largestHrefBytes: largest };
}

export async function renderSticker(document: StickerDocument, assets: RenderAssets): Promise<StickerRender> {
  const startedAt = Date.now();
  const missing = referencedAssetIds(document).filter((id) => !assets.has(id));
  traceEvent("render:sticker:start", {
    kind: document.kind,
    layers: document.layers.length,
    assets: assets.size,
    // Not an error — these draw as labelled placeholders — but it is the first thing to check when
    // the agent reports that its artwork is not in the render.
    missingAssets: missing,
  });
  const { svg, times, width, height } = documentSvg(document, await prepareSheetAssets(document, assets));
  try {
    // `density` matters: librsvg rasterises at 72dpi by default, and the SVG's own width/height are
    // in px, so leaving it alone is what keeps the output exactly `width`x`height`.
    const sheet = await sharp(Buffer.from(svg), { density: 72 })
      .webp({ quality: SHEET_QUALITY })
      .toBuffer();
    traceEvent("render:sticker:ok", {
      ms: Date.now() - startedAt,
      width,
      height,
      frames: times.length,
      svgBytes: svg.length,
      sheetBytes: sheet.byteLength,
      mimeType: SHEET_MIME,
    });
    return { bytes: new Uint8Array(sheet), mimeType: SHEET_MIME, times, width, height };
  } catch (error) {
    // The one line that says *why* `view_sticker` came back as a tool error rather than an image.
    // librsvg's messages name neither the attribute nor the asset, so the sizes have to come from
    // here or the next occurrence is as undiagnosable as the last.
    traceEvent("render:sticker:fail", {
      ms: Date.now() - startedAt,
      width,
      height,
      frames: times.length,
      ...svgDiagnostics(svg),
      error: describeError(error),
    });
    throw error;
  }
}
