import { describe, expect, it } from "vitest";
import parity from "@/fixtures/sprite-frame-index-parity.json";
import { spriteFrameIndex } from "@/lib/animation/sample";

const frames = (durations: number[]) => durations.map((duration) => ({ duration }));

/**
 * The fixture is generated from this implementation, so here it only proves the function is stable;
 * its real job is `SpriteFrameIndexParityTests` on the Swift side, which asserts the same numbers.
 */
describe("spriteFrameIndex parity fixture", () => {
  for (const testCase of parity.cases) {
    it(`matches the recorded expectations for ${testCase.name}`, () => {
      expect(parity.times.map((time) => spriteFrameIndex(frames(testCase.durations), time))).toEqual(testCase.expected);
    });
  }
});

describe("spriteFrameIndex", () => {
  const idle = frames([2.4, 0.18, 0.28, 0.22, 0.3, 1.2]);

  it("walks per-frame durations and loops on the clip's own total", () => {
    expect(spriteFrameIndex(idle, 0)).toBe(0);
    expect(spriteFrameIndex(idle, 2.39)).toBe(0);
    expect(spriteFrameIndex(idle, 2.4)).toBe(1);
    expect(spriteFrameIndex(idle, 2.58)).toBe(2);
    expect(spriteFrameIndex(idle, 4.57)).toBe(5);
    // 4.58 is the total, so the clip has wrapped back to its first frame.
    expect(spriteFrameIndex(idle, 4.58)).toBe(0);
    expect(spriteFrameIndex(idle, 4.58 + 2.5)).toBe(1);
  });

  it("holds the first frame before time zero and for degenerate clips", () => {
    expect(spriteFrameIndex(idle, -1)).toBe(0);
    expect(spriteFrameIndex(frames([3]), 100)).toBe(0);
    expect(spriteFrameIndex([], 1)).toBe(0);
    expect(spriteFrameIndex(idle, Number.NaN)).toBe(0);
  });
});
