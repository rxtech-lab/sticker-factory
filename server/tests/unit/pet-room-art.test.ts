import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { CHROMA_BLUE, CHROMA_GREEN } from "@/lib/ai/chroma-key";
import {
  renderRoomArt, renderThemeArt, ROOM_ART_HEIGHT, ROOM_ART_WIDTH, ROOM_CLOCK_KEY, ROOM_STATUS_KEY, ROOM_WEATHER_KEY, roomWindowKey,
} from "@/lib/pets/room-art";

/** A drawn room: warm walls, a floor, and a window of `glass` in its upper half. */
async function room(glass: string, window = { width: 400, height: 360 }): Promise<Uint8Array> {
  const svg = `<svg width="1024" height="1536" xmlns="http://www.w3.org/2000/svg">
    <rect width="1024" height="1536" fill="#f0d6a8"/><rect y="1000" width="1024" height="536" fill="#c9a77c"/>
    <rect x="312" y="160" width="${window.width}" height="${window.height}" fill="${glass}"/></svg>`;
  return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
}

/**
 * A room with a round clock in a dark wooden rim on the left, a framed board on the right, and a
 * wide status board in the foreground.
 */
async function furnishedRoom(): Promise<Uint8Array> {
  const svg = `<svg width="1024" height="1536" xmlns="http://www.w3.org/2000/svg">
    <rect width="1024" height="1536" fill="#f0d6a8"/><rect y="1000" width="1024" height="536" fill="#c9a77c"/>
    <rect x="312" y="160" width="400" height="360" fill="${CHROMA_GREEN.hex}"/>
    <circle cx="160" cy="320" r="100" fill="#5a3b22"/><circle cx="160" cy="320" r="88" fill="${ROOM_CLOCK_KEY.hex}"/>
    <rect x="760" y="620" width="200" height="140" fill="#2f2f2f"/>
    <rect x="772" y="632" width="176" height="116" fill="${ROOM_WEATHER_KEY.hex}"/>
    <rect x="232" y="900" width="560" height="270" fill="#3b2a1a"/>
    <rect x="246" y="914" width="532" height="242" fill="${ROOM_STATUS_KEY.hex}"/></svg>`;
  return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
}

async function pixelAt(bytes: Uint8Array, x: number, y: number): Promise<number[]> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const offset = (y * info.width + x) * info.channels;
  return [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]];
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

  it("finds the blank clock face, weather board and status board, and paints them over as plain surfaces", async () => {
    const art = await renderRoomArt(await furnishedRoom(), CHROMA_GREEN);
    expect(art.windowFraction).toBeGreaterThan(0.05);
    const { clock, weather, status } = art.fixtures;
    expect(clock).toMatchObject({ shape: "round" });
    expect(clock!.x).toBeCloseTo(72 / 1024, 2);
    expect(clock!.y).toBeCloseTo(232 / 1536, 2);
    expect(clock!.width).toBeCloseTo(177 / 1024, 2);
    expect(weather).toMatchObject({ shape: "rect" });
    expect(weather!.x).toBeCloseTo(772 / 1024, 2);
    expect(weather!.height).toBeCloseTo(116 / 1536, 2);
    // Larger than the clock and the board, and still found.
    expect(status).toMatchObject({ shape: "rect" });
    expect(status!.x).toBeCloseTo(246 / 1024, 2);
    expect(status!.y).toBeCloseTo(914 / 1536, 2);
    expect(status!.width).toBeCloseTo(532 / 1024, 2);
    // A dark rim inks the face in its own colour; neither face is left in its key colour, or keyed out.
    const ink = clock!.ink.slice(1).match(/../g)!.map((channel) => parseInt(channel, 16));
    [0x5a, 0x3b, 0x22].forEach((channel, index) => expect(Math.abs(ink[index] - channel)).toBeLessThanOrEqual(3));
    for (const [x, y] of [[120, 240], [645, 517], [384, 780]]) {
      const [r, g, b, a] = await pixelAt(art.bytes, x, y);
      expect(a).toBe(255);
      expect(Math.min(r, g, b)).toBeGreaterThan(180);
    }
  });

  it("gives no fixture when the model left out the clock or the board", async () => {
    const art = await renderRoomArt(await room(CHROMA_GREEN.hex), CHROMA_GREEN);
    expect(art.fixtures).toEqual({ clock: null, weather: null, status: null });
  });

  it("finds a place's fixtures without cutting anything out of it", async () => {
    const art = await renderThemeArt(await furnishedRoom());
    expect(art.fixtures.clock).not.toBeNull();
    expect(art.fixtures.weather).not.toBeNull();
    expect(art.fixtures.status).not.toBeNull();
    // The green screen stays as drawn: a place has no window to see through.
    expect(await alphaAt(art.bytes, 384, 255)).toBe(255);
  });
});
