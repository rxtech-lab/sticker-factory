import sharp from "sharp";
import { loopedTime } from "@/lib/animation/sample";
import { EXPORT_LOOP_HOLD_SECONDS, resolveStickerConfiguration, type StickerDocument } from "@/lib/contracts/sticker";
import { frameFragment, IdFactory, type RenderAssets } from "@/lib/render/document-svg";
import { encodeApng } from "@/lib/render/apng";
import { prepareRenderAssets } from "@/lib/render/sticker-render";

/**
 * Renders the publishable renditions of a document — the files `bindExports` binds to a revision.
 *
 * The iOS app has always rendered these; this is the second implementation, and it exists so a
 * sticker created inside the Messages extension can be published without the extension carrying the
 * app's whole export stack (see `lib/services/quick-publish.ts`). It draws through the same SVG
 * renderer the agent's `view_sticker` sheet uses, which comes with that renderer's caveats —
 * librsvg lays out text with the deploy image's fonts, shape geometry is re-derived, particles use
 * the preview formula. For artwork the generator produced (image layers on a transparent canvas)
 * the two renderers agree pixel for pixel; for a document with text, shapes or particles in it, a
 * server publish and an app publish will differ in the details.
 *
 * Every timing decision here answers to `validateAnimatedRenditionTiming` in
 * `lib/services/stickers.ts`, which is the contract the publish is checked against. That function is
 * the spec; this is the thing written to satisfy it.
 */

/** A play-once export has no repeat to separate, so nothing is held. Mirrors `exportHoldSeconds`. */
function holdSeconds(loop: StickerDocument["loop"]): number {
  return loop === "once" ? 0 : EXPORT_LOOP_HOLD_SECONDS;
}

export interface RenditionTiming {
  /** Wall-clock seconds one full play occupies, ping-pong's way back included. */
  cycleSeconds: number;
  /** The still tail that separates one repeat from the next. */
  holdSeconds: number;
  /** Document-time instants to draw, one per frame. */
  times: number[];
  /** How long each frame is shown, in whole milliseconds. Sums to the export's exact duration. */
  delaysMs: number[];
  /** 0 repeats forever; 1 settles on the last frame. */
  playCount: number;
}

/**
 * The frame grid an animated rendition is rendered on.
 *
 * `speed` divides elapsed time on the way into the interpolator rather than rewriting keyframes, so
 * a document at 2x plays its authored duration in half the wall clock. Exports are wall clock, which
 * is why the cycle divides by it — and why the *sampling* below multiplies it straight back out:
 * `sampleLayerState` wants document time, not wall time.
 *
 * @param fps the grid to sample on. The sharing and attachment renditions pass the document's own,
 *   because their frame count is checked exactly. The system rendition walks this down to fit
 *   Apple's 500 KB ceiling, which its looser fps window in `validateAnimatedRenditionTiming` exists
 *   to admit.
 */
export function animatedRenditionTiming(
  document: Extract<StickerDocument, { kind: "animated" }>,
  fps: number,
): RenditionTiming {
  document = resolveStickerConfiguration(document);
  const playbackSeconds = document.durationSeconds / Math.max(document.speed, 0.0001);
  const cycleSeconds = playbackSeconds * (document.loop === "pingPong" ? 2 : 1);
  const hold = holdSeconds(document.loop);
  const frameCount = Math.max(2, Math.ceil(cycleSeconds * fps));

  const documentCycle = document.durationSeconds * (document.loop === "pingPong" ? 2 : 1);
  const times = Array.from({ length: frameCount }, (_, index) => loopedTime(
    (index / frameCount) * documentCycle,
    { durationSeconds: document.durationSeconds, loop: document.loop },
  ));

  // Cumulative rounding rather than a rounded per-frame constant: at 30 fps a naive round drifts up
  // to half a millisecond per frame, and a 250-frame export would land ~125 ms off a duration the
  // publish checks to within about 43 ms.
  const totalMs = cycleSeconds * 1_000;
  const delaysMs = Array.from({ length: frameCount }, (_, index) => (
    Math.round((totalMs * (index + 1)) / frameCount) - Math.round((totalMs * index) / frameCount)
  ));
  delaysMs[frameCount - 1] += Math.round(hold * 1_000);

  return {
    cycleSeconds,
    holdSeconds: hold,
    times,
    delaysMs,
    playCount: document.loop === "once" ? 1 : 0,
  };
}

/**
 * How large a bitmap is worth carrying into a render at `size`.
 *
 * Twice the box, so a layer scaled past 1 still has pixels, and capped because each raster is
 * inlined as a base64 `data:` URI and libxml2 refuses a single attribute over 10 MB.
 */
function assetEdgeFor(size: number): number {
  return Math.min(2 * size, 2_048);
}

function frameSvg(document: StickerDocument, time: number, size: number, assets: RenderAssets): string {
  const ids = new IdFactory();
  const { body, defs } = frameFragment(document, time, size, assets, ids);
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" `
    + `width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">`
    + `<defs>${defs.join("")}</defs>${body}</svg>`;
}

/**
 * Rasterises one instant.
 *
 * `density: 72` matters: librsvg rasterises at 72 dpi by default and the SVG's own width/height are
 * in px, so leaving it alone is what keeps the output exactly `size` square. Nothing is flattened —
 * a sticker is transparent, and every kind this feeds validates that it contains alpha.
 */
async function rasterise(svg: string, size: number, palette: boolean): Promise<Uint8Array> {
  const png = await sharp(Buffer.from(svg), { density: 72 })
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    // `palette: false` is load-bearing for an animated rendition: an indexed frame carries its own
    // PLTE, and the APNG stitcher keeps only frame 0's, so quantising per frame would recolour the
    // animation from frame 1 on. A still rendition has no such constraint and quantising is the
    // cheapest way under the 500 KB ceiling, so the caller chooses.
    .png({ compressionLevel: 9, adaptiveFiltering: true, palette })
    .toBuffer();
  return new Uint8Array(png);
}

/** Assets fitted for a render of `times` at `size`, prepared once and reused across every frame. */
export async function prepareRenditionAssets(
  document: StickerDocument,
  assets: RenderAssets,
  size: number,
  times: number[],
): Promise<RenderAssets> {
  return prepareRenderAssets(document, assets, {
    times,
    assetEdge: assetEdgeFor(size),
    cellEdge: assetEdgeFor(size),
  });
}

/** One transparent square PNG of the document at rest. */
export async function renderStillPng(
  document: StickerDocument,
  assets: RenderAssets,
  size: number,
  options: { palette?: boolean } = {},
): Promise<Uint8Array> {
  document = resolveStickerConfiguration(document);
  const fitted = await prepareRenditionAssets(document, assets, size, [0]);
  return rasterise(frameSvg(document, 0, size, fitted), size, options.palette ?? false);
}

/** Instants weighed when choosing an animated pose, and the edge they are weighed at. */
const POSE_SAMPLES = 8;
const POSE_SAMPLE_EDGE = 48;

/**
 * One transparent square PNG of the document *settled* — the still a pet is shown as.
 *
 * Not `renderStillPng`: that draws t=0, and an animated sticker whose layers fade or slide in is an
 * empty square there. This weighs a handful of instants across the cycle and keeps the most covered
 * one, the same rule the app's `StickerPosterFrame` picks a library still by — intros build up to
 * that pose and outros decay from it. Quantised, because the watch and the widget only ever show it
 * small and both carry it across a process boundary.
 */
export async function renderPosePng(document: StickerDocument, assets: RenderAssets, size: number): Promise<Uint8Array> {
  document = resolveStickerConfiguration(document);
  const times = document.kind === "animated" ? poseTimes(document) : [0];
  const fitted = await prepareRenditionAssets(document, assets, size, times);
  let best = times[0];
  if (times.length > 1) {
    let bestCoverage = -1;
    // Sequential for the same memory reason `renderApng` gives; the samples are tiny anyway.
    for (const time of times) {
      const alpha = await sharp(Buffer.from(frameSvg(document, time, POSE_SAMPLE_EDGE, fitted)), { density: 72 })
        .resize(POSE_SAMPLE_EDGE, POSE_SAMPLE_EDGE, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
        .ensureAlpha()
        .extractChannel(3)
        .raw()
        .toBuffer();
      const coverage = alpha.reduce((total, value) => total + value, 0);
      if (coverage > bestCoverage) {
        bestCoverage = coverage;
        best = time;
      }
    }
  }
  return rasterise(frameSvg(document, best, size, fitted), size, true);
}

/** `POSE_SAMPLES` evenly spaced document-time instants across one play. */
function poseTimes(document: Extract<StickerDocument, { kind: "animated" }>): number[] {
  const { times } = animatedRenditionTiming(document, POSE_SAMPLES / Math.max(document.durationSeconds, 0.1));
  if (times.length <= POSE_SAMPLES) return times;
  return Array.from({ length: POSE_SAMPLES }, (_, index) => times[Math.floor((index * times.length) / POSE_SAMPLES)]);
}

/** A transparent square APNG of the document's whole cycle, plus its loop hold. */
export async function renderApng(
  document: Extract<StickerDocument, { kind: "animated" }>,
  assets: RenderAssets,
  size: number,
  fps: number,
): Promise<{ bytes: Uint8Array; timing: RenditionTiming }> {
  document = resolveStickerConfiguration(document);
  const timing = animatedRenditionTiming(document, fps);
  const fitted = await prepareRenditionAssets(document, assets, size, timing.times);
  const frames = [];
  for (const [index, time] of timing.times.entries()) {
    // Sequential on purpose. Rasterising a whole cycle in parallel multiplies librsvg's peak
    // footprint by the frame count, and a 250-frame 618 px export is exactly where that stops
    // fitting in a function's memory.
    frames.push({
      png: await rasterise(frameSvg(document, time, size, fitted), size, false),
      delayMs: timing.delaysMs[index],
    });
  }
  return { bytes: encodeApng(frames, timing.playCount), timing };
}

/** One transparent square WebP of the document at rest — the static sticker's copy. */
export async function renderStillWebp(
  document: StickerDocument,
  assets: RenderAssets,
  size: number,
): Promise<Uint8Array> {
  document = resolveStickerConfiguration(document);
  const fitted = await prepareRenditionAssets(document, assets, size, [0]);
  const webp = await sharp(Buffer.from(frameSvg(document, 0, size, fitted)), { density: 72 })
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    .webp({ quality: WEBP_QUALITY, alphaQuality: 100 })
    .toBuffer();
  return new Uint8Array(webp);
}

/**
 * The same cycle as `renderApng`, in WebP.
 *
 * Published beside the APNG rather than instead of it — only WinkySticker's `.image` mode reads it,
 * and everything else on the platform keeps reading the APNG. The frame grid and delays are the
 * same `RenditionTiming` the APNG is built from, so `validateAnimatedRenditionTiming` holds both
 * containers to one document.
 *
 * libvips animates a WebP from one tall "toilet roll" of frames rather than from a list, which is
 * why the raster loop concatenates instead of stitching: `pageHeight` is what tells it where each
 * frame ends. Frames are rasterised sequentially for the same memory reason `renderApng` gives.
 */
export async function renderAnimatedWebp(
  document: Extract<StickerDocument, { kind: "animated" }>,
  assets: RenderAssets,
  size: number,
  fps: number,
): Promise<{ bytes: Uint8Array; timing: RenditionTiming }> {
  document = resolveStickerConfiguration(document);
  const timing = animatedRenditionTiming(document, fps);
  const fitted = await prepareRenditionAssets(document, assets, size, timing.times);
  const pages: Buffer[] = [];
  for (const time of timing.times) {
    const raw = await sharp(Buffer.from(frameSvg(document, time, size, fitted)), { density: 72 })
      .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .ensureAlpha()
      .raw()
      .toBuffer();
    pages.push(raw);
  }
  // Bound to a variable rather than written inline: libvips takes `pages`/`pageHeight` on raw
  // input, sharp's `CreateRaw` type does not list them, and an excess-property check is the only
  // thing in the way.
  const raw = {
    width: size,
    height: size * pages.length,
    channels: 4 as const,
    pages: pages.length,
    pageHeight: size,
  };
  const webp = await sharp(Buffer.concat(pages), { raw })
    // Per frame rather than as a scalar: sharp's scalar `delay` lands on frame 0 alone and leaves
    // the rest at libwebp's 100 ms default, which silently rewrites the cycle's duration.
    .webp({
      quality: WEBP_QUALITY,
      alphaQuality: 100,
      delay: timing.delaysMs,
      loop: timing.playCount,
    })
    .toBuffer();
  return { bytes: new Uint8Array(webp), timing };
}

/**
 * Lossy, because a sticker is artwork and the channel that matters is alpha — which is why
 * `alphaQuality` is pinned at 100 while colour is not. This is the same trade the app's encoder
 * makes; see `WebPEncoder.defaultQuality`.
 */
const WEBP_QUALITY = 90;
