/**
 * Emits the cross-language parity fixture for `AnimationInterpolator.spriteFrameIndex`.
 *
 * A sprite clip is walked by per-frame durations, and the server picks the frame the agent reviews
 * with `spriteFrameIndex` in `lib/animation/sample.ts` while the device picks the frame the user
 * sees with the Swift port. The fixture pins both to the same answer at the same instants,
 * including the ones that sit on a frame boundary in floating point.
 *
 * Run after any change to either implementation, then re-run the Swift tests:
 *
 *   bun run scripts/emit-sprite-parity-fixture.ts
 *   cp fixtures/sprite-frame-index-parity.json ../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/
 *   swift test --package-path ../StickerGeniOS/packages/AnimatedView
 */

import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spriteFrameIndex } from "@/lib/animation/sample";

const times = [-1, -0.25, 0, 0.05, 0.17, 0.18, 0.35, 0.5, 0.75, 1, 1.2, 2.39, 2.4, 2.58, 2.86, 3.08, 3.38, 4.57, 4.58, 5.25, 9.16, 12.7];

const cases = [
  // The RxPet idle row: a long rest, a quick blink, then a shorter hold.
  { name: "idle-rest-blink", durations: [2.4, 0.18, 0.28, 0.22, 0.3, 1.2] },
  { name: "uniform-six-at-quarter", durations: [0.25, 0.25, 0.25, 0.25, 0.25, 0.25] },
  { name: "two-frame", durations: [0.5, 1.5] },
  { name: "single-frame", durations: [3] },
  { name: "wave-eight", durations: [0.35, 0.35, 0.4, 0.4, 0.35, 0.8, 0.3, 0.3] },
].map((entry) => ({
  ...entry,
  expected: times.map((time) => spriteFrameIndex(entry.durations.map((duration) => ({ duration })), time)),
}));

const path = resolve(dirname(fileURLToPath(import.meta.url)), "../fixtures/sprite-frame-index-parity.json");
writeFileSync(path, `${JSON.stringify({ times, cases }, null, 2)}\n`);
console.log(`Wrote ${cases.length} cases x ${times.length} times to ${path}`);
