import sharp from "sharp";
import { describe, expect, it } from "vitest";
import {
  CHROMA_BLUE,
  CHROMA_GREEN,
  alternateChromaKey,
  chromaKeyBackground,
  preferredChromaKey,
} from "@/lib/ai/chroma-key";

/**
 * A generated frame as the quick model actually returns one: opaque, with a subject sitting in the
 * middle of a flooded backdrop.
 *
 * The backdrop is deliberately not the exact key colour. A real one is dithered and slightly shaded,
 * and a keyer that only recognises `#00FF00` leaves a fringe of near-green around every edge, so the
 * fixture is offset far enough to prove the matte works on dominance rather than on equality.
 */
async function generatedFrame(options: {
  background: { r: number; g: number; b: number };
  subject: { r: number; g: number; b: number };
  dimension?: number;
  subjectFraction?: number;
}): Promise<Uint8Array> {
  const dimension = options.dimension ?? 64;
  const fraction = options.subjectFraction ?? 0.5;
  const pixels = Buffer.alloc(dimension * dimension * 3);
  const inset = Math.round((dimension * (1 - fraction)) / 2);
  for (let y = 0; y < dimension; y += 1) {
    for (let x = 0; x < dimension; x += 1) {
      const inside = x >= inset && x < dimension - inset && y >= inset && y < dimension - inset;
      const colour = inside ? options.subject : options.background;
      const index = (y * dimension + x) * 3;
      pixels[index] = colour.r;
      pixels[index + 1] = colour.g;
      pixels[index + 2] = colour.b;
    }
  }
  const png = await sharp(pixels, { raw: { width: dimension, height: dimension, channels: 3 } })
    .png()
    .toBuffer();
  return new Uint8Array(png);
}

async function pixels(bytes: Uint8Array): Promise<{ data: Buffer; width: number; height: number }> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data, width: info.width, height: info.height };
}

function pixelAt(raw: { data: Buffer; width: number; height: number }, x: number, y: number) {
  const index = (y * raw.width + x) * 4;
  return {
    r: raw.data[index],
    g: raw.data[index + 1],
    b: raw.data[index + 2],
    alpha: raw.data[index + 3],
  };
}

describe("chroma key", () => {
  it("cuts an off-pure green backdrop away and leaves the subject untouched", async () => {
    const frame = await generatedFrame({
      background: { r: 18, g: 232, b: 34 },
      subject: { r: 220, g: 70, b: 90 },
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_GREEN);
    const raw = await pixels(keyed.bytes);

    // The corner is the margin the crop leaves around the subject, and it is backdrop: cleared
    // outright rather than left green under a zero alpha, which anything ignoring alpha would draw.
    expect(pixelAt(raw, 0, 0)).toEqual({ r: 0, g: 0, b: 0, alpha: 0 });
    expect(pixelAt(raw, raw.width >> 1, raw.height >> 1))
      .toMatchObject({ r: 220, g: 70, b: 90, alpha: 255 });
    // Three quarters of the frame is backdrop: 64x64 with a 32x32 subject. Measured against the
    // frame the model returned, not against what survives the crop.
    expect(keyed.keyedFraction).toBeCloseTo(0.75, 2);
  });

  it("keys blue for the subjects a green screen would swallow", async () => {
    const frame = await generatedFrame({
      background: { r: 20, g: 30, b: 235 },
      subject: { r: 40, g: 200, b: 60 },
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_BLUE);
    const raw = await pixels(keyed.bytes);

    expect(pixelAt(raw, 0, 0).alpha).toBe(0);
    // The green subject survives the blue screen whole, which is the entire point of choosing it.
    expect(pixelAt(raw, raw.width >> 1, raw.height >> 1))
      .toMatchObject({ r: 40, g: 200, b: 60, alpha: 255 });
  });

  it("crops away the empty frame the model drew around the subject", async () => {
    // A quarter-size subject in the middle of a flooded frame, which is what the quick model
    // returns when it is told to draw a background: keeping the frame would publish a sticker that
    // is mostly nothing and shows up half-size once the export ladder fits it into 618px.
    const frame = await generatedFrame({
      background: { r: 18, g: 232, b: 34 },
      subject: { r: 220, g: 70, b: 90 },
      dimension: 128,
      subjectFraction: 0.25,
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_GREEN);
    const raw = await pixels(keyed.bytes);

    // 32px of subject plus a 3% margin on each side, and square either way.
    expect(raw.width).toBe(raw.height);
    expect(raw.width).toBeGreaterThanOrEqual(32);
    expect(raw.width).toBeLessThanOrEqual(36);
    expect(pixelAt(raw, raw.width >> 1, raw.height >> 1).alpha).toBe(255);
    // And where in the model's frame the subject was, for a caller that places it by that.
    expect(keyed.subject).toBeDefined();
    expect(keyed.subject!.coverage).toBeCloseTo(0.25, 2);
    expect(keyed.subject!.crop.width).toBeCloseTo(raw.width / 128, 5);
    expect(keyed.subject!.crop.left + keyed.subject!.crop.width / 2).toBeCloseTo(0.5, 1);
  });

  it("keeps the whole frame when the subject already fills it", async () => {
    const frame = await generatedFrame({
      background: { r: 18, g: 232, b: 34 },
      subject: { r: 220, g: 70, b: 90 },
      subjectFraction: 1,
    });
    const raw = await pixels((await chromaKeyBackground(frame, CHROMA_GREEN)).bytes);
    expect(raw.width).toBe(64);
  });

  /**
   * The failure the caller retries on: nothing was keyed, so the model ignored the backdrop and
   * returned an ordinary opaque illustration.
   */
  it("reports a near-zero keyed fraction when no backdrop was drawn", async () => {
    const frame = await generatedFrame({
      background: { r: 240, g: 240, b: 240 },
      subject: { r: 220, g: 70, b: 90 },
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_GREEN);
    expect(keyed.keyedFraction).toBe(0);
    const raw = await pixels(keyed.bytes);
    expect(pixelAt(raw, 2, 2).alpha).toBe(255);
  });

  /** The opposite failure: the subject matched the screen and has been erased along with it. */
  it("reports a near-total keyed fraction when the subject matched the screen", async () => {
    const frame = await generatedFrame({
      background: { r: 18, g: 232, b: 34 },
      subject: { r: 30, g: 210, b: 40 },
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_GREEN);
    expect(keyed.keyedFraction).toBeGreaterThan(0.97);
  });

  it("despills the colour a soft edge borrows from the backdrop", async () => {
    // A half-and-half edge pixel: partly the subject's grey, partly the green screen behind it.
    const frame = await generatedFrame({
      background: { r: 18, g: 232, b: 34 },
      subject: { r: 120, g: 195, b: 125 },
    });
    const keyed = await chromaKeyBackground(frame, CHROMA_GREEN);
    const centre = pixelAt(await pixels(keyed.bytes), 32, 32);

    expect(centre.alpha).toBeGreaterThan(0);
    expect(centre.alpha).toBeLessThan(255);
    // Without the despill this stays at 195 and reads as a green halo on a dark conversation.
    expect(centre.g).toBe(125);
  });

  it("picks blue only for subjects that would disappear against green", async () => {
    expect(preferredChromaKey("a smiling red panda holding a coffee").name).toBe("green");
    expect(preferredChromaKey("a cheerful frog wearing a hat").name).toBe("blue");
    expect(preferredChromaKey("cat sitting in the GRASS").name).toBe("blue");
    expect(alternateChromaKey(CHROMA_GREEN)).toBe(CHROMA_BLUE);
    expect(alternateChromaKey(CHROMA_BLUE)).toBe(CHROMA_GREEN);
  });
});
