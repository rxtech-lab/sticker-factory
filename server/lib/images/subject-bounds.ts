import sharp from "sharp";
import { z } from "zod";

/**
 * Where the visible artwork sits inside a generated frame, and the square worth keeping.
 *
 * Every layer is drawn into a square box centred on its anchor, and the box is the only geometry
 * the layout code can reason about: overlap, off-canvas, the reviewer's placements are all computed
 * from it. That only means anything when the box describes what is visible. An image model asked
 * for one element on a transparent background does not reliably fill its frame — it draws a small
 * subject in the middle, or leaves a part exactly where it sat in the reference it was separated
 * from — and stored as-is that frame becomes a layer whose visible pixels sit somewhere inside its
 * box rather than filling it. Measuring the alpha and cropping to it is what makes the box true.
 *
 * The measurement is kept alongside the crop because the frame it was taken from carries meaning
 * of its own: a part separated from an approved reference at its original position is, by the
 * bounds of what survived, a statement of where that part belongs on the canvas.
 */

/** Alpha at or below which a pixel is backdrop haze rather than artwork the crop has to keep. */
export const VISIBLE_ALPHA = 8;

/**
 * The margin left around the subject, as a fraction of its longer edge.
 *
 * Not zero, because a sticker whose artwork runs into its own edge looks clipped rather than
 * die-cut, and the renditions are drawn from this square without any padding of their own.
 */
export const SUBJECT_MARGIN = 0.03;

/** Inclusive pixel extents; `right < left` means nothing was found. */
export type PixelBounds = { left: number; top: number; right: number; bottom: number };

export type PixelRect = { left: number; top: number; width: number; height: number };

/** A rectangle as fractions of the frame it was measured in. */
export type NormalizedRect = { left: number; top: number; width: number; height: number };

const NormalizedRectSchema = z.object({
  left: z.number().min(0).max(1),
  top: z.number().min(0).max(1),
  width: z.number().min(0).max(1),
  height: z.number().min(0).max(1),
}).strict();

/** Validated on the way back from object metadata, which is a string nobody else guards. */
export const SubjectBoundsSchema = z.object({
  /** The tight bounds of every pixel above `VISIBLE_ALPHA`. */
  bbox: NormalizedRectSchema,
  /**
   * The square actually kept: the bbox squared up with its margin and clamped to the frame, or the
   * whole frame when the subject already reached its edges. A layer holding the cropped PNG maps
   * its box onto exactly this rectangle of the source frame.
   */
  crop: NormalizedRectSchema,
  /** The subject's longer edge as a fraction of the frame — how much of it the model used. */
  coverage: z.number().min(0).max(1),
  source: z.object({ width: z.number().int().positive(), height: z.number().int().positive() }).strict(),
}).strict();

export type SubjectBounds = z.infer<typeof SubjectBoundsSchema>;

type RawInfo = { width: number; height: number; channels: number };

export function emptyPixelBounds(info: { width: number; height: number }): PixelBounds {
  return { left: info.width, top: info.height, right: -1, bottom: -1 };
}

export function extendPixelBounds(bounds: PixelBounds, x: number, y: number): void {
  if (x < bounds.left) bounds.left = x;
  if (x > bounds.right) bounds.right = x;
  if (y < bounds.top) bounds.top = y;
  if (y > bounds.bottom) bounds.bottom = y;
}

export function pixelBoundsAreEmpty(bounds: PixelBounds): boolean {
  return bounds.right < bounds.left || bounds.bottom < bounds.top;
}

/** The extents of the visible alpha in a raw RGBA buffer, or `undefined` for an empty frame. */
export function measureAlphaBounds(data: Uint8Array, info: RawInfo): PixelBounds | undefined {
  const bounds = emptyPixelBounds(info);
  const stride = info.channels;
  if (stride < 4) return { left: 0, top: 0, right: info.width - 1, bottom: info.height - 1 };
  for (let offset = 3; offset < data.length; offset += stride) {
    if (data[offset] <= VISIBLE_ALPHA) continue;
    const pixel = (offset - 3) / stride;
    const x = pixel % info.width;
    extendPixelBounds(bounds, x, (pixel - x) / info.width);
  }
  return pixelBoundsAreEmpty(bounds) ? undefined : bounds;
}

/**
 * The square to keep: the subject's bounds, squared up and given a margin.
 *
 * Squared rather than left as the subject's own rectangle so the crop cannot change the sticker's
 * proportions. A tall subject in a wide frame would otherwise come out of the later contain-resize
 * padded on the sides in a way the artist never asked for; growing the short side around the
 * subject's centre keeps it where it was drawn.
 *
 * Returns `undefined` when there is nothing to crop to — an empty frame, or a subject already
 * filling it — and the caller keeps the whole image.
 */
export function subjectCropRect(
  info: { width: number; height: number },
  bounds: PixelBounds,
): PixelRect | undefined {
  if (pixelBoundsAreEmpty(bounds)) return undefined;
  const width = bounds.right - bounds.left + 1;
  const height = bounds.bottom - bounds.top + 1;
  const size = Math.round(Math.min(
    Math.max(width, height) * (1 + SUBJECT_MARGIN * 2),
    info.width,
    info.height,
  ));
  // Nothing to take: the subject already reaches both edges, so the crop would be the frame itself.
  if (size >= info.width && size >= info.height) return undefined;
  const centreX = (bounds.left + bounds.right) / 2;
  const centreY = (bounds.top + bounds.bottom) / 2;
  return {
    left: Math.round(Math.min(Math.max(centreX - size / 2, 0), info.width - size)),
    top: Math.round(Math.min(Math.max(centreY - size / 2, 0), info.height - size)),
    width: size,
    height: size,
  };
}

/** The measurement in frame fractions, for callers that reason about the canvas rather than pixels. */
export function describeSubject(
  info: { width: number; height: number },
  bounds: PixelBounds,
  crop: PixelRect | undefined,
): SubjectBounds {
  const width = bounds.right - bounds.left + 1;
  const height = bounds.bottom - bounds.top + 1;
  const kept = crop ?? { left: 0, top: 0, width: info.width, height: info.height };
  return {
    bbox: {
      left: bounds.left / info.width,
      top: bounds.top / info.height,
      width: width / info.width,
      height: height / info.height,
    },
    crop: {
      left: kept.left / info.width,
      top: kept.top / info.height,
      width: kept.width / info.width,
      height: kept.height / info.height,
    },
    coverage: Math.max(width / info.width, height / info.height),
    source: { width: info.width, height: info.height },
  };
}

/**
 * Crops a transparent PNG to its visible subject.
 *
 * The bytes come back untouched when there is nothing to crop to, and `subject` is `undefined` only
 * for a frame with no visible pixels at all — which the caller's transparency gate rejects anyway.
 */
export async function cropPngToSubject(
  bytes: Uint8Array,
): Promise<{ bytes: Uint8Array; subject?: SubjectBounds }> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const bounds = measureAlphaBounds(data, info);
  if (!bounds) return { bytes };
  const crop = subjectCropRect(info, bounds);
  const subject = describeSubject(info, bounds, crop);
  if (!crop) return { bytes, subject };
  const png = await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } })
    .extract(crop)
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return { bytes: new Uint8Array(png), subject };
}
