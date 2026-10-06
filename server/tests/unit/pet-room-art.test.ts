import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { CHROMA_BLUE, CHROMA_GREEN } from "@/lib/ai/chroma-key";
import { renderRoomArt, ROOM_ART_HEIGHT, ROOM_ART_WIDTH, roomWindowKey } from "@/lib/pets/room-art";

/** A drawn room: warm walls, a floor, and a window of `glass` in its upper half. */
async function room(glass: string, window = { width: 400, height: 360 }): Promise<Uint8Array> {
  const svg = `<svg width="1024" height="1536" xmlns="http://www.w3.org/2000/svg">
    <rect width="1024" height="1536" fill="#f0d6a8"/><rect y="1000" width="1024" height="536" fill="#c9a77c"/>
    <rect x="312" y="160" width="${window.width}" height="${window.height}" fill="${glass}"/></svg>`;
  return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
}

async function alphaAt(bytes: Uint8Array, x: number, y: number): Promise<number> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return data[(y * info.width + x) * info.channels + 3];
}

describe("pet room art", () => {
  it("cuts the window out of the room without cropping it", async () => {
    const art = await renderRoomArt(await room(CHROMA_GREEN.hex), CHROMA_GREEN);
    const meta = await sharp(art.bytes).metadata();
    expect(meta.format).toBe("webp");
    expect([meta.width, meta.height]).toEqual([ROOM_ART_WIDTH, ROOM_ART_HEIGHT]);
    expect(art.windowFraction).toBeGreaterThan(0.05);
    // The middle of the window is see-through; the wall and floor stay solid.
    expect(await alphaAt(art.bytes, 384, 255)).toBe(0);
    expect(await alphaAt(art.bytes, 60, 60)).toBe(255);
    expect(await alphaAt(art.bytes, 384, 1100)).toBe(255);
  });

  it("keeps a room opaque when the model drew no window, or keyed the room itself", async () => {
    const plain = await renderRoomArt(await room("#f0d6a8"), CHROMA_GREEN);
    expect(plain.windowFraction).toBe(0);
    expect(await alphaAt(plain.bytes, 384, 255)).toBe(255);
    const flooded = await renderRoomArt(await room(CHROMA_GREEN.hex, { width: 712, height: 1376 }), CHROMA_GREEN);
    expect(flooded.windowFraction).toBe(0);
    expect(await alphaAt(flooded.bytes, 384, 255)).toBe(255);
  });

  it("paints leafy rooms' windows blue so their plants survive", () => {
    expect(roomWindowKey("A sunny attic bedroom with a round window")).toBe(CHROMA_GREEN);
    expect(roomWindowKey("A mossy forest burrow full of ferns and leaves")).toBe(CHROMA_BLUE);
  });
});
