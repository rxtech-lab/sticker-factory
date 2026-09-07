import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { inspectWebM } from "@/lib/storage/r2";

/**
 * `inspectWebM` against a file the app itself produced.
 *
 * The fixture is a 512², 30-frame, 1.2 s transparent VP9 WebM written by
 * `packages/VP9Encoder`'s own encoder on an iOS simulator — the same encoder that will upload
 * Telegram renditions in production. Regenerate it by encoding 30 frames of anything at 512² with
 * `VP9WebMEncoder(settings: .fitting(byteBudget: 256 * 1024, durationMilliseconds: 1200))` and
 * copying the bytes here; there is no way to make one on the server, which is the whole reason this
 * pipeline runs on the phone.
 */
const webm = () => new Uint8Array(readFileSync("fixtures/messenger-telegram-512.webm"));

describe("inspectWebM", () => {
  it("reads dimensions, codec and duration out of a real encoder's output", () => {
    const inspection = inspectWebM(webm());
    expect(inspection.width).toBe(512);
    expect(inspection.height).toBe(512);
    expect(inspection.codec).toBe("V_VP9");
    // 30 frames at 40 ms. Floating point through the timecode scale, so compared with a tolerance.
    expect(inspection.durationSeconds).toBeCloseTo(1.2, 3);
    expect(inspection.byteSize).toBe(webm().byteLength);
    expect(inspection.sha256).toMatch(/^[a-f0-9]{64}$/);
  });

  it("refuses anything that is not a Matroska file", () => {
    const png = new Uint8Array(200);
    png.set([0x89, 0x50, 0x4e, 0x47], 0);
    expect(() => inspectWebM(png)).toThrow(/Matroska/);
  });

  it("refuses a file too short to hold a header", () => {
    expect(() => inspectWebM(webm().subarray(0, 32))).toThrow(/Matroska/);
  });

  /**
   * A truncated file is the interesting failure: every element it does contain is well-formed, and
   * a reader that trusted declared sizes would walk straight off the end of the buffer. It must
   * come back as a 422 rather than a crash — these are bytes an uploader chose.
   */
  it("refuses a truncated file without reading past the buffer", () => {
    const truncated = webm().subarray(0, 120);
    expect(() => inspectWebM(truncated)).toThrowError(
      expect.objectContaining({ status: 422 }),
    );
  });

  it("survives arbitrary garbage after a valid magic number", () => {
    const bytes = webm().slice(0, 400);
    bytes.fill(0xff, 8);
    // Whatever it decides, it must decide it as a 422 and not by hanging or throwing a TypeError.
    expect(() => inspectWebM(bytes)).toThrowError(
      expect.objectContaining({ status: 422 }),
    );
  });
});
