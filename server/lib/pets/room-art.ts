import sharp from "sharp";
import { chromaKeyBackground, preferredChromaKey, type ChromaKeyColor } from "@/lib/ai/chroma-key";

/** Rooms are stored once, at the size the tab fills a large phone with. */
export const ROOM_ART_WIDTH = 768;
export const ROOM_ART_HEIGHT = 1152;

/**
 * Below this share of the frame keyed, the model drew no window (or a speck of stray colour);
 * above it, the key colour ran into the room itself. Either way the room is kept whole and opaque
 * rather than shipped with holes the weather would show through.
 */
const MIN_WINDOW_FRACTION = 0.01;
const MAX_WINDOW_FRACTION = 0.4;

/**
 * The screen a room's windows are painted in. Green keys cleanest, but a mossy, leafy room keeps
 * its plants only against blue, so the scene decides, the same way a quick sticker's prompt does.
 */
export function roomWindowKey(scene: string): ChromaKeyColor {
  return preferredChromaKey(scene);
}

/**
 * Cuts the window screen out of a drawn room and stores it as a portrait WebP with alpha, so the
 * app can show the owner's weather through the glass. A room whose key failed stays opaque.
 */
export async function renderRoomArt(
  bytes: Uint8Array,
  windowKey: ChromaKeyColor,
): Promise<{ bytes: Uint8Array; windowFraction: number }> {
  const keyed = await chromaKeyBackground(bytes, windowKey, { crop: false });
  const usable = keyed.keyedFraction >= MIN_WINDOW_FRACTION && keyed.keyedFraction <= MAX_WINDOW_FRACTION;
  const webp = await sharp(usable ? keyed.bytes : bytes)
    .resize(ROOM_ART_WIDTH, ROOM_ART_HEIGHT, { fit: "cover" })
    .webp({ quality: 86, alphaQuality: 100 })
    .toBuffer();
  return { bytes: new Uint8Array(webp), windowFraction: usable ? keyed.keyedFraction : 0 };
}
