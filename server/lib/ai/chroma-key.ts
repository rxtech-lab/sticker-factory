import sharp from "sharp";

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
 * square into 618px, the part anyone can see ends up half the size it should be. The main model has
 * no such habit — asked for a transparent background it fills the frame — so the crop lives here
 * rather than in `normalizeTransparentPng`, which both paths share.
 */
export async function chromaKeyBackground(
  bytes: Uint8Array,
  color: ChromaKeyColor,
): Promise<{ bytes: Uint8Array; keyedFraction: number }> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const stride = info.channels;
  // Red rivals both keys; the third channel is whichever of green and blue is not the key.
  const rivalA = 0;
  const rivalB = color.channel === 1 ? 2 : 1;
  let removed = 0;
  const bounds = { left: info.width, top: info.height, right: -1, bottom: -1 };
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
    const y = (pixel - x) / info.width;
    if (x < bounds.left) bounds.left = x;
    if (x > bounds.right) bounds.right = x;
    if (y < bounds.top) bounds.top = y;
    if (y > bounds.bottom) bounds.bottom = y;
  }
  const keyed = sharp(data, {
    raw: { width: info.width, height: info.height, channels: stride as 4 },
  });
  const subject = cropToSubject(info, bounds);
  const png = await (subject ? keyed.extract(subject) : keyed)
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return {
    bytes: new Uint8Array(png),
    keyedFraction: removed / (info.width * info.height),
  };
}

/** Alpha at or below which a pixel is backdrop haze rather than artwork the crop has to keep. */
const VISIBLE_ALPHA = 8;

/**
 * The margin left around the subject, as a fraction of its longer edge.
 *
 * Not zero, because a sticker whose artwork runs into its own edge looks clipped rather than
 * die-cut, and the renditions are drawn from this square without any padding of their own.
 */
const SUBJECT_MARGIN = 0.03;

/**
 * The square to keep: the subject's bounds, squared up and given a margin.
 *
 * Squared rather than left as the subject's own rectangle so the crop cannot change the sticker's
 * proportions. A tall subject in a wide frame would otherwise come out of the later contain-resize
 * padded on the sides in a way the artist never asked for; growing the short side around the
 * subject's centre keeps it where it was drawn.
 *
 * Returns `undefined` when there is nothing to crop to — an empty key, or a subject already filling
 * the frame — and the caller keeps the whole image.
 */
function cropToSubject(
  info: { width: number; height: number },
  bounds: { left: number; top: number; right: number; bottom: number },
): { left: number; top: number; width: number; height: number } | undefined {
  if (bounds.right < bounds.left || bounds.bottom < bounds.top) return undefined;
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
