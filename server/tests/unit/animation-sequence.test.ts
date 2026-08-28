import { describe, expect, it } from "vitest";
import parity from "@/fixtures/sequence-frame-index-parity.json";
import { sequenceFrameIndex } from "@/lib/animation/sample";

type Playback = "loop" | "once" | "pingPong";
type SequenceLike = { frameCount: number; frameRate: number; playback: Playback; startSeconds: number };

const layerOf = (raw: (typeof parity.cases)[number]["layer"]): SequenceLike => ({
  frameCount: raw.frameCount,
  frameRate: raw.frameRate,
  playback: raw.playback as Playback,
  startSeconds: raw.startSeconds,
});

/**
 * The fixture is generated from this implementation, so on its own it only proves the function is
 * stable. Its real job is on the Swift side, where `SequenceFrameIndexParityTests` asserts the same
 * numbers: together they pin the two renderers to one answer. Keeping the TS half here means a
 * regression shows up in `bun run test` too, rather than only in a simulator build.
 */
describe("sequenceFrameIndex parity fixture", () => {
  for (const testCase of parity.cases) {
    it(`matches the recorded expectations for ${testCase.name}`, () => {
      const layer = layerOf(testCase.layer);
      expect(parity.times.map((time) => sequenceFrameIndex(layer, time))).toEqual(testCase.expected);
    });
  }
});

describe("sequenceFrameIndex", () => {
  const layer = (overrides: Partial<SequenceLike> = {}): SequenceLike => ({
    frameCount: 12,
    frameRate: 10,
    playback: "loop",
    startSeconds: 0,
    ...overrides,
  });

  it("holds the first tile before the layer starts rather than hiding it", () => {
    // A sequence that vanished for its first second would read as a failed asset load.
    expect(sequenceFrameIndex(layer({ startSeconds: 0.5 }), 0)).toBe(0);
    expect(sequenceFrameIndex(layer({ startSeconds: 0.5 }), -3)).toBe(0);
    expect(sequenceFrameIndex(layer({ startSeconds: 0.5 }), 0.5)).toBe(0);
    expect(sequenceFrameIndex(layer({ startSeconds: 0.5 }), 0.65)).toBe(1);
  });

  /**
   * `0.6 - 0.5` is 0.09999999999999998, so the second tile begins a hair after the arithmetic
   * boundary rather than exactly on it. Pinned rather than corrected: Swift does the same IEEE-754
   * subtraction in the same order and lands on the same tile, which is what parity actually
   * requires. Rounding the elapsed time here would break that agreement, and the visible error is
   * one frame at one instant of a 10 fps sequence.
   */
  it("resolves a frame boundary the same way floating point does", () => {
    expect(sequenceFrameIndex(layer({ startSeconds: 0.5 }), 0.6)).toBe(0);
    expect(sequenceFrameIndex(layer({ startSeconds: 0 }), 0.1)).toBe(1);
  });

  it("clamps to the last tile when playback is once", () => {
    expect(sequenceFrameIndex(layer({ playback: "once" }), 1.1)).toBe(11);
    expect(sequenceFrameIndex(layer({ playback: "once" }), 60)).toBe(11);
  });

  it("wraps when playback loops", () => {
    expect(sequenceFrameIndex(layer(), 1.2)).toBe(0);
    expect(sequenceFrameIndex(layer(), 1.3)).toBe(1);
  });

  it("walks back down the sheet when playback ping-pongs", () => {
    expect(sequenceFrameIndex(layer({ playback: "pingPong" }), 1.1)).toBe(11);
    expect(sequenceFrameIndex(layer({ playback: "pingPong" }), 1.2)).toBe(10);
    // 2n-2 frames per cycle, so the sequence is back at tile 0 after 22 ticks.
    expect(sequenceFrameIndex(layer({ playback: "pingPong" }), 2.2)).toBe(0);
  });

  it("never divides by zero on a single-frame sheet", () => {
    for (const playback of ["loop", "once", "pingPong"] as const) {
      expect(sequenceFrameIndex(layer({ frameCount: 1, playback }), 7.5)).toBe(0);
    }
  });

  it("stays inside the sheet for every playback mode at arbitrary times", () => {
    for (const playback of ["loop", "once", "pingPong"] as const) {
      for (let time = -2; time < 12; time += 0.017) {
        const index = sequenceFrameIndex(layer({ playback, frameCount: 7, frameRate: 13 }), time);
        expect(index).toBeGreaterThanOrEqual(0);
        expect(index).toBeLessThan(7);
        expect(Number.isInteger(index)).toBe(true);
      }
    }
  });
});
