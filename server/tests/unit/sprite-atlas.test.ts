import { expect, it } from "vitest";
import sharp from "sharp";
import { padGeneratedAtlas } from "@/lib/render/sprite-atlas";
import { registerFaceSlots } from "@/lib/render/sprite-registration";
import { validateGeneratedAtlas } from "@/workflows/sticker-generation/configurable-artwork";

const grid = { columns: 3, rows: 2, frameCount: 6 };
const drawing = (x: number, y: number) => `<rect x="${x}" y="${y}" width="330" height="180" fill="blue"/><ellipse cx="${x + 150}" cy="${y + 60}" rx="40" ry="30" fill="#ff00ff"/>`;
async function sheet(extra = "") {
  // Full silhouettes, separated by narrow gaps, but crossing the nominal 341px boundaries.
  const frames = [18, 355, 690].flatMap((x) => [200, 650].map((y) => drawing(x, y))).join("");
  return sharp(Buffer.from(`<svg width="1024" height="1024">${frames}${extra}</svg>`)).png().toBuffer();
}

it("recovers intact silhouettes across cell boundaries at one scale and registers every face", async () => {
  const original = await sheet();
  await expect(validateGeneratedAtlas(original, grid)).rejects.toThrow("frame 1 is clipped");
  const repaired = await padGeneratedAtlas(original, grid);
  await expect(validateGeneratedAtlas(repaired, grid)).resolves.toBeUndefined();
  const registered = await registerFaceSlots(repaired, grid);
  expect(registered.frames).toHaveLength(6);
  const sizes = registered.frames.map((frame) => frame.faceSize);
  expect(Math.max(...sizes) - Math.min(...sizes)).toBeLessThan(0.01);
  const { data, info } = await sharp(repaired).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let marginPixels = 0;
  for (let frame = 0; frame < 6; frame++) {
    const ox = (frame % 3) * 341, oy = Math.floor(frame / 3) * 512;
    for (let y = 0; y < 512; y++) for (let x = 0; x < 341; x++) {
      if ((x < 48 || x > 293 || y < 72 || y > 440) && data[((oy + y) * info.width + ox + x) * 4 + 3] > 24) marginPixels++;
    }
  }
  expect(marginPixels).toBe(0);
});

it("refuses to hide artwork clipped at the sheet's outer edge", async () => {
  await expect(padGeneratedAtlas(await sheet('<rect x="0" y="250" width="30" height="90" fill="blue"/>'), grid)).rejects.toThrow("outer edge");
});

it("refuses overlapping drawings with no clear seam", async () => {
  await expect(padGeneratedAtlas(await sheet('<rect x="280" y="270" width="150" height="50" fill="blue"/>'), grid)).rejects.toThrow("clear gaps");
});

it("does not silently drop drawings in unused cells", async () => {
  await expect(padGeneratedAtlas(await sheet(), { ...grid, frameCount: 5 })).rejects.toThrow("unused cells");
});

it("does not manufacture a missing frame", async () => {
  const empty = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer();
  await expect(padGeneratedAtlas(empty, grid)).rejects.toThrow("empty sprite frame");
});
