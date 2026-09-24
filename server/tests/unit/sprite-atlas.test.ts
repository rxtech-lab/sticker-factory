import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { anchorSpriteFrames, padGeneratedAtlas, validateGeneratedAtlas } from "@/lib/render/sprite-atlas";
import { registerFaceSlots } from "@/lib/render/sprite-registration";

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

it("repairs the reported wing overshoot instead of failing the pose", async () => {
  // The artifact this was all reported for: six poses that sit properly in their cells, except
  // frame 1, whose wing runs past x=341 and reappears as a sliver inside frame 2.
  const plane = (x: number, y: number) => `<ellipse cx="${x + 120}" cy="${y + 90}" rx="110" ry="70" fill="blue"/>`;
  const cells = [0, 1, 2].flatMap((column) => [0, 1].map((row) => plane(column * 341 + 50, row * 512 + 160))).join("");
  const bytes = await sharp(Buffer.from(`<svg width="1024" height="1024">${cells}<rect x="300" y="240" width="70" height="14" fill="blue"/></svg>`)).png().toBuffer();
  await expect(validateGeneratedAtlas(bytes, grid)).rejects.toThrow("frame 1 is clipped");
  const repaired = await padGeneratedAtlas(bytes, grid);
  await expect(validateGeneratedAtlas(repaired, grid)).resolves.toBeUndefined();
  // The wing is carried across, not trimmed off: frame 1 stays wider than its wingless neighbour.
  const { data, info } = await sharp(repaired).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const spread = (cell: number) => {
    const ox = (cell % 3) * 341, oy = Math.floor(cell / 3) * 512;
    let left = 341, right = -1;
    for (let y = 0; y < 512; y++) for (let x = 0; x < 341; x++) {
      if (data[((oy + y) * info.width + ox + x) * 4 + 3] <= 24) continue;
      left = Math.min(left, x); right = Math.max(right, x);
    }
    return right - left;
  };
  expect(spread(0)).toBeGreaterThan(spread(1));
});

it("recovers poses that interlock across the boundary, where no straight seam exists", async () => {
  // One pose reaches right along the top, the next reaches left along the bottom. Every vertical
  // line between them crosses one arm or the other, so cutting the grid on clear columns refused
  // this sheet outright — although both drawings are whole and separate.
  const interlocked = { columns: 2, rows: 1, frameCount: 2 };
  const bytes = await sharp(Buffer.from('<svg width="1024" height="512"><g fill="blue">'
    + '<rect x="60" y="100" width="340" height="300"/><rect x="400" y="120" width="200" height="40"/>'
    + '<rect x="640" y="100" width="340" height="300"/><rect x="440" y="340" width="200" height="40"/>'
    + "</g></svg>")).png().toBuffer();
  await expect(validateGeneratedAtlas(bytes, interlocked)).rejects.toThrow("clipped");
  const repaired = await padGeneratedAtlas(bytes, interlocked);
  await expect(validateGeneratedAtlas(repaired, interlocked)).resolves.toBeUndefined();
});

it("erases alpha specks rather than condemning the sheet they landed on", async () => {
  // Three pixels in the corner: invisible at display size, and sitting exactly where the rim check
  // looks for a silhouette the sheet cut off.
  const repaired = await padGeneratedAtlas(await sheet('<rect x="0" y="0" width="3" height="3" fill="blue"/>'), grid);
  await expect(validateGeneratedAtlas(repaired, grid)).resolves.toBeUndefined();
});

it("erases a speck left in a cell nothing was asked for", async () => {
  const used = [18, 355, 690].flatMap((x) => [200, 650].map((y) => ({ x, y })))
    .filter((at) => !(at.x === 690 && at.y === 650))
    .map((at) => drawing(at.x, at.y)).join("");
  const speckled = await sharp(Buffer.from(`<svg width="1024" height="1024">${used}<rect x="800" y="800" width="4" height="4" fill="blue"/></svg>`)).png().toBuffer();
  const repaired = await padGeneratedAtlas(speckled, { ...grid, frameCount: 5 });
  await expect(validateGeneratedAtlas(repaired, { ...grid, frameCount: 5 })).resolves.toBeUndefined();
});

it("does not manufacture a missing frame", async () => {
  const empty = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer();
  await expect(padGeneratedAtlas(empty, grid)).rejects.toThrow("empty sprite frame");
});

describe("anchorSpriteFrames", () => {
  const steadyGrid = { columns: 2, rows: 2, frameCount: 4 };
  // 512px cells. Each frame is a body standing on `ground`, with a face placeholder on it.
  const body = (cell: number, ground: number, height = 200) => {
    const x = (cell % 2) * 512 + 156, y = Math.floor(cell / 2) * 512 + ground - height;
    return `<rect x="${x}" y="${y}" width="200" height="${height}" fill="blue"/><ellipse cx="${x + 100}" cy="${y + 60}" rx="40" ry="30" fill="#ff00ff"/>`;
  };
  const render = (frames: string) => sharp(Buffer.from(`<svg width="1024" height="1024">${frames}</svg>`)).png().toBuffer();
  const groundOf = async (bytes: Uint8Array, cell: number) => {
    const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const ox = (cell % 2) * 512, oy = Math.floor(cell / 2) * 512;
    let ground = -1;
    for (let y = 0; y < 512; y++) for (let x = 0; x < 512; x++) {
      if (data[((oy + y) * info.width + ox + x) * 4 + 3] > 24) ground = y;
    }
    return ground;
  };

  it("stands every frame on frame 1's ground line", async () => {
    // A bob the model drew but nobody asked for: frames 2-4 sit higher than frame 1.
    const bytes = await render([body(0, 420), body(1, 380), body(2, 350), body(3, 400)].join(""));
    const anchored = await anchorSpriteFrames(bytes, steadyGrid);
    await expect(validateGeneratedAtlas(anchored, steadyGrid)).resolves.toBeUndefined();
    const grounds = await Promise.all([0, 1, 2, 3].map((cell) => groundOf(anchored, cell)));
    expect(new Set(grounds).size).toBe(1);
    expect(grounds[0]).toBe(await groundOf(bytes, 0));
    // The face moved with the body, so it still registers in every frame.
    expect((await registerFaceSlots(anchored, steadyGrid)).frames).toHaveLength(4);
  });

  it("keeps a stretch that only moves the top of the silhouette", async () => {
    // Same feet, taller body: nothing to correct.
    const bytes = await render([body(0, 420), body(1, 420, 260), body(2, 420, 170), body(3, 420)].join(""));
    expect(await anchorSpriteFrames(bytes, steadyGrid)).toBe(bytes);
  });

  it("moves a frame only as far as its cell's safe margin allows", async () => {
    // Frame 2 stands lower than frame 1 and is nearly as tall as its cell: lifting it all the way
    // to frame 1's line would push its head past the top margin, so it rises only to the margin.
    const bytes = await render([body(0, 400), body(1, 470, 440), body(2, 400), body(3, 400)].join(""));
    const anchored = await anchorSpriteFrames(bytes, steadyGrid);
    await expect(validateGeneratedAtlas(anchored, steadyGrid)).resolves.toBeUndefined();
    const before = await groundOf(bytes, 1), after = await groundOf(anchored, 1);
    expect(after).toBeLessThan(before);
    expect(after).toBeGreaterThan(await groundOf(anchored, 0));
  });

  it("ignores specks when finding the ground line", async () => {
    // A stray dot under frame 1's feet: counted as ground, it would drag every other frame down.
    const speck = '<rect x="250" y="455" width="2" height="2" fill="blue"/>';
    const bytes = await render([body(0, 420), body(1, 420), body(2, 420), body(3, 420), speck].join(""));
    expect(await anchorSpriteFrames(bytes, steadyGrid)).toBe(bytes);
  });
});
