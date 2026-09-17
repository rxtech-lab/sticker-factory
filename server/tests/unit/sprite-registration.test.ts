import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { FACE_OVERCOVER, compositeSpriteFrame, registerExpressionTiles, registerFaceSlots } from "@/lib/render/sprite-registration";

const CELL = { width: 120, height: 160 };
const GRID = { columns: 3, rows: 2, frameCount: 6 };

/** A 3x2 sheet of orange bodies, each with a magenta oval face at a known spot. */
async function bodySheet(faces: Array<{ cx: number; cy: number; rx: number; ry: number } | null>, body = "#F4A261"): Promise<Uint8Array> {
  const cells = faces.map((face, index) => {
    const ox = (index % GRID.columns) * CELL.width, oy = Math.floor(index / GRID.columns) * CELL.height;
    return `<rect x="${ox + 20}" y="${oy + 20}" width="${CELL.width - 40}" height="${CELL.height - 40}" rx="30" fill="${body}"/>`
      + (face ? `<ellipse cx="${ox + face.cx}" cy="${oy + face.cy}" rx="${face.rx}" ry="${face.ry}" fill="#FF00FF"/>` : "");
  }).join("");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${CELL.width * GRID.columns}" height="${CELL.height * GRID.rows}">${cells}</svg>`;
  return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
}

const pixel = async (bytes: Uint8Array, x: number, y: number) => {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const offset = (y * info.width + x) * info.channels;
  return [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]];
};

type Face = { cx: number; cy: number; rx: number; ry: number } | null;
const regular: Face[] = Array.from({ length: 6 }, (_, index) => ({ cx: 60 + index, cy: 60, rx: 24, ry: 20 }));

describe("registerFaceSlots", () => {
  it("measures each cell's placeholder and paints it out with the surrounding colour", async () => {
    const { bytes, frames } = await registerFaceSlots(await bodySheet(regular), GRID);
    expect(frames).toHaveLength(6);
    frames.forEach((frame, index) => {
      expect(frame.faceX).toBeCloseTo((60 + index) / CELL.width, 2);
      expect(frame.faceY).toBeCloseTo(60 / CELL.height, 2);
      expect(frame.faceSize).toBeCloseTo(48 / CELL.width, 1);
    });
    // The slot is now body-coloured, and nothing magenta is left anywhere on the sheet.
    const [r, g, b, a] = await pixel(bytes, 60, 60);
    expect(a).toBe(255);
    expect(Math.abs(r - 0xF4) + Math.abs(g - 0xA2) + Math.abs(b - 0x61)).toBeLessThan(12);
    const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    let magenta = 0;
    for (let index = 0; index < info.width * info.height; index += 1) {
      const offset = index * info.channels;
      if (data[offset + 3] > 200 && data[offset] > 150 && data[offset + 2] > 150 && data[offset + 1] < 0.45 * Math.min(data[offset], data[offset + 2])) magenta += 1;
    }
    expect(magenta).toBe(0);
    // Transparent padding survives: the inpaint never touches pixels outside the placeholder.
    expect((await pixel(bytes, 2, 2))[3]).toBe(0);
  });

  it("names the frame whose placeholder is missing, oversized, scattered, or clipped", async () => {
    const missing = [...regular]; missing[3] = null;
    await expect(registerFaceSlots(await bodySheet(missing), GRID)).rejects.toThrow("frame 4 has no face placeholder");
    const huge = [...regular]; huge[1] = { cx: 60, cy: 80, rx: 58, ry: 78 };
    await expect(registerFaceSlots(await bodySheet(huge), GRID)).rejects.toThrow(/frame 2 .*(clipped|covering)/);
    const clipped = [...regular]; clipped[5] = { cx: 110, cy: 60, rx: 24, ry: 20 };
    await expect(registerFaceSlots(await bodySheet(clipped), GRID)).rejects.toThrow("frame 6 has its face placeholder clipped");
  });
});

describe("registerExpressionTiles and compositeSpriteFrame", () => {
  const faceSheet = async () => {
    const tiles = ["#2A9D8F", "#264653", "#E76F51"].map((colour, index) => {
      const ox = index * 100;
      return `<ellipse cx="${ox + 50}" cy="40" rx="30" ry="24" fill="${colour}"/>`;
    }).join("");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="300" height="100">${tiles}</svg>`;
    return new Uint8Array(await sharp(Buffer.from(svg)).png().toBuffer());
  };

  it("measures tight tile bounds normalized to the sheet", async () => {
    const tiles = await registerExpressionTiles(await faceSheet(), { columns: 3, rows: 1, frameCount: 3 });
    expect(tiles).toHaveLength(3);
    expect(tiles[1].x * 300).toBeCloseTo(100 + 20 - 2, 0);
    expect(tiles[1].width * 300).toBeCloseTo(60 + 4, 0);
    expect(tiles[1].height * 100).toBeCloseTo(48 + 4, 0);
    const empty = new Uint8Array(await sharp({ create: { width: 300, height: 100, channels: 4, background: "#00000000" } }).png().toBuffer());
    await expect(registerExpressionTiles(empty, { columns: 3, rows: 1, frameCount: 3 })).rejects.toThrow("Expression 1 is empty");
  });

  it("draws the chosen face into the frame's slot, scaled to the slot's width", async () => {
    const { bytes: atlas, frames } = await registerFaceSlots(await bodySheet(regular), GRID);
    const sheet = await faceSheet();
    const tiles = await registerExpressionTiles(sheet, { columns: 3, rows: 1, frameCount: 3 });
    const composed = await compositeSpriteFrame({ atlas, clip: { ...GRID, frames }, index: 4, sheet, tile: tiles[2] });
    const meta = await sharp(composed).metadata();
    expect([meta.width, meta.height]).toEqual([CELL.width, CELL.height]);
    // Frame 4's slot is centred at x=64: the face colour sits there, and the body colour just past
    // the slot's overcovered edge.
    const centre = await pixel(composed, 64, 60);
    expect(Math.abs(centre[0] - 0xE7) + Math.abs(centre[1] - 0x6F) + Math.abs(centre[2] - 0x51)).toBeLessThan(12);
    const faceWidth = frames[4].faceSize * CELL.width * FACE_OVERCOVER;
    const outside = await pixel(composed, Math.round(64 + faceWidth / 2 + 4), 60);
    expect(Math.abs(outside[0] - 0xF4) + Math.abs(outside[1] - 0xA2) + Math.abs(outside[2] - 0x61)).toBeLessThan(12);
    // A different expression changes the slot and nothing else.
    const other = await compositeSpriteFrame({ atlas, clip: { ...GRID, frames }, index: 4, sheet, tile: tiles[0] });
    const otherCentre = await pixel(other, 64, 60);
    expect(Math.abs(otherCentre[0] - 0x2A) + Math.abs(otherCentre[1] - 0x9D) + Math.abs(otherCentre[2] - 0x8F)).toBeLessThan(12);
    expect(await pixel(other, 30, 130)).toEqual(await pixel(composed, 30, 130));
    // Shrunk to a review tile when asked.
    const small = await sharp(await compositeSpriteFrame({ atlas, clip: { ...GRID, frames }, index: 0, sheet, tile: tiles[0], edge: 64 })).metadata();
    expect(Math.max(small.width!, small.height!)).toBe(64);
  });

  it("keeps foreground props above a masked face and accepts a fully covered face", async () => {
    const cells = regular.map((face, index) => {
      const ox = (index % GRID.columns) * CELL.width, oy = Math.floor(index / GRID.columns) * CELL.height;
      const marker = index === 5 ? "" : `<ellipse cx="${ox + face!.cx}" cy="${oy + face!.cy}" rx="${face!.rx}" ry="${face!.ry}" fill="#FF00FF"/>`;
      // The cup is drawn after the marker. Frame 6 covers the complete registered face.
      const cup = index === 5
        ? `<ellipse cx="${ox + 65}" cy="${oy + 60}" rx="34" ry="28" fill="#663300"/>`
        : `<rect x="${ox + 36}" y="${oy + 58}" width="48" height="24" rx="8" fill="#663300"/>`;
      return `<rect x="${ox + 20}" y="${oy + 20}" width="80" height="120" rx="30" fill="#F4A261"/>${marker}${cup}`;
    }).join("");
    const body = new Uint8Array(await sharp(Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="360" height="320">${cells}</svg>`,
    )).png().toBuffer());
    const registeredFrames = regular.map((face) => ({
      faceX: face!.cx / CELL.width,
      faceY: face!.cy / CELL.height,
      faceSize: face!.rx * 2 / CELL.width,
    }));
    const registered = await registerFaceSlots(body, GRID, {
      faceCompositing: "masked",
      registeredFrames,
    });
    expect(registered.frames).toEqual(registeredFrames);
    expect(registered.maskBytes).toBeDefined();
    const sheet = await faceSheet();
    const tiles = await registerExpressionTiles(sheet, { columns: 3, rows: 1, frameCount: 3 });
    const partial = await compositeSpriteFrame({
      atlas: registered.bytes, maskAtlas: registered.maskBytes,
      clip: { ...GRID, frames: registered.frames, faceCompositing: "masked" }, index: 0, sheet, tile: tiles[0],
    });
    const visibleFace = await pixel(partial, 60, 49);
    expect(visibleFace[1]).toBeGreaterThan(visibleFace[0]); // green expression
    expect(visibleFace[1]).toBeGreaterThan(visibleFace[2]);
    const cup = await pixel(partial, 60, 68);
    expect(cup[0]).toBeGreaterThan(cup[1]);
    expect(cup[2]).toBeLessThan(40);

    const covered = await compositeSpriteFrame({
      atlas: registered.bytes, maskAtlas: registered.maskBytes,
      clip: { ...GRID, frames: registered.frames, faceCompositing: "masked" }, index: 5, sheet, tile: tiles[0],
    });
    const coveredCentre = await pixel(covered, 65, 60);
    expect(coveredCentre[0]).toBeGreaterThan(coveredCentre[1]);
    expect(coveredCentre[2]).toBeLessThan(40);
  });
});
