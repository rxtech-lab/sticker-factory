import sharp from "sharp";
import {
  describeSubject,
  emptyPixelBounds,
  extendPixelBounds,
  pixelBoundsAreEmpty,
  subjectCropRect,
  VISIBLE_ALPHA,
  type SubjectBounds,
} from "@/lib/images/subject-bounds";

/**
 * Turning a solid coloured backdrop into alpha, because the quick image model cannot draw one.
 *
 * The main path asks `gpt-image-2` for a transparent PNG and gets one. The quick model
 * (`AI_QUICK_IMAGE_MODEL`) is a fraction of the price and a fraction of the wait, but it has no
 * transparent-background mode at all: every image it returns is fully opaque. So quick mode borrows
 * the oldest trick in film — shoot the subject against a colour nothing in the subject shares, then
 * remove that colour afterwards. The model is told to fill the background with pure green or pure
 * blue, and this module cuts it back out.
 *
 * Keying is done on channel *dominance* rather than distance to the exact colour, because a
 * generated backdrop is never exactly `#00FF00`: it is dithered, faintly shaded, and slightly
 * darkened where the subject casts onto it. Dominance — how far the key channel runs ahead of the
 * brightest of the other two — stays large across all of that, and stays small for every colour a
 * sticker subject is actually made of, including saturated greens that are not *pure* green.
 */

export interface ChromaKeyColor {
  name: "green" | "blue";
  /** The exact colour the image model is told to flood the background with. */
  hex: string;
  /** Which RGB channel the backdrop runs away in. Green is 1, blue is 2. */
  channel: 1 | 2;
}

export const CHROMA_GREEN: ChromaKeyColor = { name: "green", hex: "#00FF00", channel: 1 };
export const CHROMA_BLUE: ChromaKeyColor = { name: "blue", hex: "#0000FF", channel: 2 };

/**
 * Words that make a green screen the wrong choice, so the backdrop becomes blue instead.
 *
 * A green frog on green is a frog-shaped hole. There is no way to recover from that after the fact
 * — the pixels are gone — so the guess has to be made before the image exists, from the only thing
 * available at that point: the instruction. It is deliberately trigger-happy. Keying a green subject
 * against blue costs nothing, while the reverse costs the whole sticker.
 */
const GREEN_SUBJECT_HINTS =
  /\b(green|grass|grassy|leaf|leaves|foliage|forest|jungle|frog|toad|lime|mint|emerald|jade|olive|moss|mossy|cactus|avocado|cucumber|broccoli|shrek|alien|zombie|dinosaur|dragon|turtle|tortoise|lizard|crocodile|snake|caterpillar|seaweed|clover|shamrock|pickle|kiwi|matcha|teal)\b/i;

/**
 * Picks the backdrop this particular sticker can safely be shot against.
 *
 * Green first, because it is what image models render most cleanly and most uniformly, and blue is
 * far commoner in subjects — skies, water, denim, eyes. Only a hint of green in the subject flips it.
 */
export function preferredChromaKey(prompt: string): ChromaKeyColor {
  return GREEN_SUBJECT_HINTS.test(prompt) ? CHROMA_BLUE : CHROMA_GREEN;
}

/** The other backdrop, for the retry after a key that took everything or nothing. */
export function alternateChromaKey(color: ChromaKeyColor): ChromaKeyColor {
  return color.name === "green" ? CHROMA_BLUE : CHROMA_GREEN;
}

/**
 * Dominance at or above which a pixel is background outright, and at or below which it is subject.
 *
 * Between them the pixel is an edge — antialiasing that is genuinely part backdrop, part subject —
 * and gets a partial alpha, which is what keeps a keyed sticker from looking cut out with scissors.
 * The band is wide because the ramp is where the quality lives: a hard threshold turns every hair,
 * whisker, and soft shadow into a staircase.
 */
const OPAQUE_DOMINANCE = 40;
const KEYED_DOMINANCE = 110;

/**
 * Removes the key colour from an opaque generated image and returns a PNG with real alpha.
 *
 * Two things happen per pixel. The obvious one is the matte: dominance decides how much of the
 * pixel was backdrop, and alpha is reduced by that much. The less obvious one is the despill —
 * every edge pixel keeps a rim of the backdrop's colour bleeding into it, and left alone that rim
 * reads as a green halo the moment the sticker lands on a dark conversation background. Clamping
 * the key channel down to the brightest rival channel removes the tint while leaving the pixel's
 * own colour and its luminance essentially intact.
 *
 * `keyedFraction` is returned rather than kept private because it is the only cheap signal for the
 * two ways this can go wrong: near zero means the model ignored the backdrop instruction, and near
 * one means the subject was the key colour and has just been erased. The caller retries both
 * against the other backdrop rather than publishing an opaque rectangle or an empty sticker.
 *
 * The result is also cropped to what survived. Told to draw on a background, the quick model draws
 * a *scene*: a small subject sitting in the middle of a large flooded frame. Keyed and left alone
 * that becomes a sticker two thirds of which is empty, and since the export ladder fits the whole
 * square into 618px, the part anyone can see ends up half the size it should be. The crop is fused
 * into the keying pass rather than taken from `cropPngToSubject` afterwards because the matte
 * already visits every pixel; the measurement itself is the shared one (`lib/images/subject-bounds`).
 */
export async function chromaKeyBackground(
  bytes: Uint8Array,
  color: ChromaKeyColor,
  options: { crop?: boolean } = {},
): Promise<{ bytes: Uint8Array; keyedFraction: number; subject?: SubjectBounds }> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const stride = info.channels;
  // Red rivals both keys; the third channel is whichever of green and blue is not the key.
  const rivalA = 0;
  const rivalB = color.channel === 1 ? 2 : 1;
  let removed = 0;
  const bounds = emptyPixelBounds(info);
  for (let offset = 0; offset < data.length; offset += stride) {
    const key = data[offset + color.channel];
    const rival = Math.max(data[offset + rivalA], data[offset + rivalB]);
    const dominance = key - rival;
    if (dominance > OPAQUE_DOMINANCE) {
      if (dominance >= KEYED_DOMINANCE) {
        // Cleared, not merely hidden. A fully transparent pixel that keeps its colour is still a
        // green pixel to anything that reads the file without honouring alpha — a thumbnailer, a
        // flatten onto white, a resize that forgets to premultiply — and the sticker arrives with
        // the screen it was shot against showing through.
        data[offset] = 0;
        data[offset + 1] = 0;
        data[offset + 2] = 0;
        data[offset + 3] = 0;
        removed += 1;
        continue;
      }
      const keyness = (dominance - OPAQUE_DOMINANCE) / (KEYED_DOMINANCE - OPAQUE_DOMINANCE);
      data[offset + 3] = Math.round(data[offset + 3] * (1 - keyness));
      data[offset + color.channel] = rival;
      removed += keyness;
    }
    // Measured against a threshold rather than against zero, so the faint haze a lossy encoder
    // leaves in the flooded area cannot pin the crop back out to the full frame.
    if (data[offset + 3] <= VISIBLE_ALPHA) continue;
    const pixel = offset / stride;
    const x = pixel % info.width;
    extendPixelBounds(bounds, x, (pixel - x) / info.width);
  }
  const keyed = sharp(data, {
    raw: { width: info.width, height: info.height, channels: stride as 4 },
  });
  // A scene keyed for its windows is the whole frame, not a subject on a backdrop: never cropped.
  const crop = options.crop === false ? undefined : subjectCropRect(info, bounds);
  const png = await (crop ? keyed.extract(crop) : keyed)
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return {
    bytes: new Uint8Array(png),
    keyedFraction: removed / (info.width * info.height),
    subject: pixelBoundsAreEmpty(bounds) ? undefined : describeSubject(info, bounds, crop),
  };
}

/**
 * Picks the backdrop a still can safely be animated against, by looking at the still itself.
 *
 * `preferredChromaKey` has to guess from a prompt because it is called before the image exists. A
 * clip made from artwork the sticker already carries has the opposite problem and the better data:
 * the pixels are right there, so the subject's own colour decides instead of a word list. That
 * matters more here than it does for a quick draw — the still is keyed back out *on the device*
 * after the video model has flattened the subject onto the screen, and a subject that shares the
 * screen colour comes back as a hole with no way to recover it.
 *
 * The measure is the same dominance the keyer uses, averaged over the visible pixels: how far green
 * runs ahead of its rivals versus how far blue does. The screen becomes whichever channel the
 * subject leans on less, with green winning ties because it keys most cleanly.
 */
export async function chromaKeyForArtwork(bytes: Uint8Array): Promise<ChromaKeyColor> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const stride = info.channels;
  let green = 0;
  let blue = 0;
  let visible = 0;
  for (let offset = 0; offset < data.length; offset += stride) {
    if (data[offset + 3] <= VISIBLE_ALPHA) continue;
    visible += 1;
    // Clamped at zero: a pixel where the channel is *not* dominant says nothing about whether that
    // screen is risky, and letting it go negative would let a large neutral area cancel out the
    // handful of vividly green pixels that are the whole reason to switch.
    green += Math.max(0, data[offset + 1] - Math.max(data[offset], data[offset + 2]));
    blue += Math.max(0, data[offset + 2] - Math.max(data[offset], data[offset + 1]));
  }
  // Nothing visible at all: the still is empty or unreadable, so fall back to the usual default
  // rather than reading a decision out of an all-zero measurement.
  if (visible === 0) return CHROMA_GREEN;
  return green > blue ? CHROMA_BLUE : CHROMA_GREEN;
}
