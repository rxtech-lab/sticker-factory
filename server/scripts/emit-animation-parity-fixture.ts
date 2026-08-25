/**
 * Emits the cross-language parity fixture for `AnimatedView`'s Swift animation compiler.
 *
 * The Swift port in `StickerGeniOS/packages/AnimatedView/Sources/AnimatedView/Engine/AnimationCompiler.swift`
 * must produce byte-identical keyframes to `lib/animation/compile.ts`, because a document stores
 * both its declarative specs and their compiled output and the document schema rejects any document
 * where the two disagree. A Swift client that compiled even one keyframe differently would write
 * documents the server refuses.
 *
 * Run after any change to the compiler, then re-run the Swift tests:
 *
 *   bun run scripts/emit-animation-parity-fixture.ts
 *   swift test --package-path ../StickerGeniOS/packages/AnimatedView
 */

import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { compileLayerAnimation, type AnimationTiming } from "@/lib/animation/compile";
import { DEFAULT_ANCHOR, type AnimationAnchorV1, type AnimationSpecV1 } from "@/lib/contracts/animation";
import { AnimationSpecV1Schema } from "@/lib/contracts/animation";

type Case = {
  name: string;
  timing: AnimationTiming;
  anchor: AnimationAnchorV1;
  cycleCap?: number;
  specs: unknown[];
};

const animated = (durationSeconds = 4): AnimationTiming => ({ kind: "animated", durationSeconds });
const offsetAnchor: AnimationAnchorV1 = {
  position: { x: 0.34, y: 0.62 },
  scale: { x: 0.75, y: 1.25 },
  rotationDegrees: -18,
  opacity: 0.8,
};

/**
 * Every spec type at its defaults, then again with explicit non-default parameters, then the
 * combinations that exercise anchor folding, easing on the closing keyframe, touching windows, and
 * the cycle cap. Defaults matter as much as explicit values: they are applied by zod on one side and
 * by the Swift decoder on the other, so a drifted default would show up here and nowhere else.
 */
const cases: Case[] = [
  { name: "empty", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [] },
  { name: "empty-with-anchor", timing: animated(), anchor: offsetAnchor, specs: [] },

  { name: "fadeIn-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "fadeIn" }] },
  { name: "fadeOut-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "fadeOut" }] },
  { name: "popIn-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "popIn" }] },
  { name: "popOut-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "popOut" }] },
  {
    name: "slideIn-defaults",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    specs: [{ type: "slideIn", direction: "up" }],
  },
  {
    name: "slideOut-defaults",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    specs: [{ type: "slideOut", direction: "left" }],
  },
  { name: "moveTo", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "moveTo", x: 0.2, y: 0.8 }] },
  { name: "scaleTo", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "scaleTo", x: 1.6, y: 0.4 }] },
  { name: "rotateTo", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "rotateTo", degrees: -135 }] },
  { name: "spin-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "spin" }] },
  { name: "wiggle-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "wiggle" }] },
  { name: "pulse-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "pulse" }] },
  { name: "bounce-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "bounce" }] },
  { name: "float-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "float" }] },
  { name: "blurIn-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "blurIn" }] },
  { name: "blurOut-defaults", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "blurOut" }] },
  { name: "hueShift", timing: animated(), anchor: DEFAULT_ANCHOR, specs: [{ type: "hueShift", degrees: -140 }] },

  // Explicit parameters, non-default easings, and a non-zero delay.
  {
    name: "popIn-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "popIn", from: 0.17, delay: 0.35, duration: 1.25, easing: "springBouncy" }],
  },
  {
    name: "slideIn-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "slideIn", direction: "right", distance: 0.85, delay: 0.5, duration: 0.75, easing: "easeOut" }],
  },
  {
    name: "spin-ccw",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "spin", turns: 2.75, direction: "ccw", duration: 3, easing: "linear" }],
  },
  {
    name: "wiggle-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "wiggle", amplitudeDegrees: 33, cycles: 5, delay: 0.2, duration: 3.3, easing: "easeInOut" }],
  },
  {
    name: "pulse-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "pulse", minScale: 0.31, maxScale: 2.7, cycles: 4, duration: 2.8, easing: "springSoft" }],
  },
  {
    name: "bounce-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "bounce", height: 0.37, bounces: 5, delay: 0.1, duration: 3.5 }],
  },
  {
    name: "float-explicit",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [{ type: "float", amplitude: 0.23, cycles: 6, duration: 3.6, easing: "easeIn" }],
  },
  {
    name: "blurIn-explicit",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    specs: [{ type: "blurIn", radius: 17.5, delay: 0.25, duration: 1.75, easing: "easeOut" }],
  },

  // Clamping: values the compiler must pin to the schema's bounds rather than pass through.
  {
    name: "clamp-position",
    timing: animated(),
    anchor: { ...DEFAULT_ANCHOR, position: { x: 0.02, y: 0.98 } },
    specs: [{ type: "slideIn", direction: "down", distance: 1, duration: 1 }],
  },
  {
    name: "clamp-rotation",
    timing: animated(),
    anchor: { ...DEFAULT_ANCHOR, rotationDegrees: 900 },
    specs: [{ type: "spin", turns: 3, direction: "cw", duration: 2 }],
  },
  {
    name: "clamp-scale",
    timing: animated(),
    anchor: { ...DEFAULT_ANCHOR, scale: { x: 7, y: 7 } },
    specs: [{ type: "pulse", minScale: 0.05, maxScale: 4, cycles: 1, duration: 1 }],
  },

  // Multiple specs: separate channels, touching windows on one channel, and anchor folding for the
  // channels nobody drives.
  {
    name: "multi-channel",
    timing: animated(),
    anchor: offsetAnchor,
    specs: [
      { type: "popIn", delay: 0, duration: 0.6, easing: "springBouncy" },
      { type: "wiggle", amplitudeDegrees: 12, cycles: 2, delay: 0.6, duration: 1.4 },
      { type: "hueShift", degrees: 90, delay: 2, duration: 1 },
    ],
  },
  {
    name: "touching-windows",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    specs: [
      { type: "fadeIn", delay: 0, duration: 1 },
      { type: "fadeOut", delay: 1, duration: 1 },
    ],
  },
  {
    name: "staggered-entrance",
    timing: animated(),
    anchor: { ...DEFAULT_ANCHOR, position: { x: 0.25, y: 0.4 } },
    specs: [
      { type: "slideIn", direction: "up", distance: 0.4, delay: 0.4, duration: 0.6, easing: "springBouncy" },
      { type: "float", amplitude: 0.05, cycles: 2, delay: 1, duration: 2 },
    ],
  },

  // The budget lever: the same cyclic spec compiled at a reduced cycle cap.
  {
    name: "cycle-cap-2",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    cycleCap: 2,
    specs: [{ type: "wiggle", amplitudeDegrees: 20, cycles: 7, duration: 3.5 }],
  },
  {
    name: "cycle-cap-1",
    timing: animated(),
    anchor: DEFAULT_ANCHOR,
    cycleCap: 1,
    specs: [{ type: "bounce", height: 0.3, bounces: 6, duration: 3 }],
  },

  // Short durations, where the 4-decimal time rounding actually bites.
  {
    name: "short-duration-rounding",
    timing: animated(1.7),
    anchor: DEFAULT_ANCHOR,
    specs: [{ type: "wiggle", amplitudeDegrees: 7, cycles: 3, delay: 0.13, duration: 1.37 }],
  },
];

const output = cases.map((testCase) => {
  const specs = testCase.specs.map((spec) => AnimationSpecV1Schema.parse(spec) as AnimationSpecV1);
  return {
    name: testCase.name,
    timing: testCase.timing,
    anchor: testCase.anchor,
    cycleCap: testCase.cycleCap ?? null,
    // The *parsed* specs, with every zod default materialised. The Swift side decodes exactly these,
    // so a defaulting difference fails the test instead of hiding inside the compiled output.
    specs,
    expected: compileLayerAnimation(specs, testCase.anchor, testCase.timing, testCase.cycleCap ?? Number.POSITIVE_INFINITY),
  };
});

const here = dirname(fileURLToPath(import.meta.url));
const destination = resolve(
  here,
  "../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/animation-compiler-parity.json",
);
writeFileSync(destination, `${JSON.stringify(output, null, 2)}\n`);
console.log(`Wrote ${output.length} parity cases to ${destination}`);
