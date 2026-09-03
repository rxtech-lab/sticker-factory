import sharp from "sharp";
import { describe, expect, it } from "vitest";
import {
  cropPngToSubject,
  measureAlphaBounds,
  SUBJECT_MARGIN,
  subjectCropRect,
} from "@/lib/images/subject-bounds";

/**
 * A transparent frame with one opaque block in it, the way an image model returns a single element
 * it did not bother to fill the frame with.
 */
async function transparentFrame(options: {
  dimension?: number;
  block?: { left: number; top: number; width: number; height: number };
}): Promise<Uint8Array> {
  const dimension = options.dimension ?? 128;
  const pixels = Buffer.alloc(dimension * dimension * 4);
  const block = options.block;
  if (block) {
    for (let y = block.top; y < block.top + block.height; y += 1) {
      for (let x = block.left; x < block.left + block.width; x += 1) {
        const index = (y * dimension + x) * 4;
        pixels[index] = 220;
        pixels[index + 1] = 70;
        pixels[index + 2] = 90;
        pixels[index + 3] = 255;
      }
    }
  }
  const png = await sharp(pixels, { raw: { width: dimension, height: dimension, channels: 4 } })
    .png()
    .toBuffer();
  return new Uint8Array(png);
}

describe("subject bounds", () => {
  it("measures the visible pixels and squares the crop around their centre with a margin", async () => {
    const block = { left: 16, top: 40, width: 32, height: 20 };
    const { bytes, subject } = await cropPngToSubject(await transparentFrame({ block }));
    expect(subject).toBeDefined();
    expect(subject!.bbox).toEqual({ left: 16 / 128, top: 40 / 128, width: 32 / 128, height: 20 / 128 });
    expect(subject!.coverage).toBeCloseTo(0.25, 5);
    expect(subject!.source).toEqual({ width: 128, height: 128 });

    // The longer edge plus the margin on each side, and square either way.
    const side = Math.round(32 * (1 + SUBJECT_MARGIN * 2));
    expect(subject!.crop.width).toBeCloseTo(side / 128, 5);
    expect(subject!.crop.height).toBeCloseTo(side / 128, 5);
    // Centred on the subject's centre (32, 50), not on its top-left corner.
    expect(subject!.crop.left + subject!.crop.width / 2).toBeCloseTo(32 / 128, 1);
    expect(subject!.crop.top + subject!.crop.height / 2).toBeCloseTo(50 / 128, 1);

    const cropped = await sharp(bytes).metadata();
    expect(cropped.width).toBe(side);
    expect(cropped.height).toBe(side);
  });

  it("keeps the whole frame, and says so, when the subject already fills it", async () => {
    const frame = await transparentFrame({ block: { left: 0, top: 0, width: 128, height: 128 } });
    const { bytes, subject } = await cropPngToSubject(frame);
    expect(bytes).toBe(frame);
    expect(subject?.crop).toEqual({ left: 0, top: 0, width: 1, height: 1 });
    expect(subject?.coverage).toBe(1);
  });

  it("clamps a crop that would run past the frame edge", async () => {
    const block = { left: 100, top: 100, width: 28, height: 28 };
    const { subject } = await cropPngToSubject(await transparentFrame({ block }));
    expect(subject!.crop.left + subject!.crop.width).toBeLessThanOrEqual(1);
    expect(subject!.crop.top + subject!.crop.height).toBeLessThanOrEqual(1);
    expect(subject!.crop.width).toBeGreaterThan(28 / 128);
  });

  it("reports nothing for a frame with no visible pixels", async () => {
    const frame = await transparentFrame({});
    const { bytes, subject } = await cropPngToSubject(frame);
    expect(subject).toBeUndefined();
    expect(bytes).toBe(frame);
  });

  it("ignores backdrop haze below the visible threshold", () => {
    const info = { width: 4, height: 4, channels: 4 };
    const data = new Uint8Array(4 * 4 * 4);
    // Faint alpha everywhere, one real pixel at (2, 1).
    for (let index = 3; index < data.length; index += 4) data[index] = 4;
    data[(1 * 4 + 2) * 4 + 3] = 255;
    expect(measureAlphaBounds(data, info)).toEqual({ left: 2, top: 1, right: 2, bottom: 1 });
    expect(subjectCropRect(info, { left: 2, top: 1, right: 2, bottom: 1 })).toEqual({
      left: 2, top: 1, width: 1, height: 1,
    });
  });
});
