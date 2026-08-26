import { z } from "zod";

/**
 * Keyframe and declarative-animation contracts.
 *
 * These live here rather than in `contracts/sticker` so the compiler in `lib/animation/compile`
 * can depend on them without a cycle: `sticker` imports both this module and the compiler, and the
 * compiler imports only this module. `contracts/sticker` re-exports every keyframe symbol, so
 * existing `@/lib/contracts/sticker` imports keep working.
 */

export const StickerEasingV1Schema = z.enum([
  "linear",
  "easeIn",
  "easeOut",
  "easeInOut",
  "springSoft",
  "springBouncy",
]);

/**
 * The longest a sticker may run.
 *
 * v1 capped this at 4s. v2 widens it to 30 to match `AnimatedDocument.durationRange` on the Swift
 * side — the two compilers must accept exactly the same inputs or a document authored on one would
 * be rejected by the other.
 */
export const MAX_TIME_SECONDS = 30;

const KeyframeBaseSchema = z.object({
  /** Absolute time in seconds from the beginning of the sticker. */
  timeSeconds: z.number().min(0).max(MAX_TIME_SECONDS),
  /**
   * Governs the segment *ending* at this keyframe.
   *
   * The renderer reads easing from the upper keyframe of the pair it is blending
   * (`StickerInterpolator.interpolate`), so the easing on the first keyframe of a channel is never
   * used. The compiler relies on this when it emits `start`/`end` pairs.
   */
  easing: StickerEasingV1Schema.default("linear"),
}).strict();

export const PositionKeyframeV1Schema = KeyframeBaseSchema.extend({
  x: z.number().min(-1).max(2),
  y: z.number().min(-1).max(2),
}).strict();

export const ScaleKeyframeV1Schema = KeyframeBaseSchema.extend({
  x: z.number().min(0.05).max(8),
  y: z.number().min(0.05).max(8),
}).strict();

export const RotationKeyframeV1Schema = KeyframeBaseSchema.extend({
  degrees: z.number().min(-1080).max(1080),
}).strict();

export const OpacityKeyframeV1Schema = KeyframeBaseSchema.extend({
  value: z.number().min(0).max(1),
}).strict();

export const EffectKeyframeV1Schema = KeyframeBaseSchema.extend({
  blurRadius: z.number().min(0).max(20).default(0),
  hueDegrees: z.number().min(-180).max(180).default(0),
  saturation: z.number().min(0).max(2).default(1),
}).strict();

/**
 * A normalized window over a path's length, driving draw-on animation.
 *
 * `start`/`end` are fractions of the total length, mirroring SwiftUI's `Shape.trim(from:to:)`, so a
 * `0 → 1` sweep of `end` is a stroke drawing itself on. Layers with no geometry to trim — images,
 * text, particles — ignore the channel entirely.
 */
export const TrimKeyframeV1Schema = KeyframeBaseSchema.extend({
  start: z.number().min(0).max(1).default(0),
  end: z.number().min(0).max(1).default(1),
}).strict();

export const LayerAnimationV1Schema = z.object({
  position: z.array(PositionKeyframeV1Schema).max(32).default([]),
  scale: z.array(ScaleKeyframeV1Schema).max(32).default([]),
  rotation: z.array(RotationKeyframeV1Schema).max(32).default([]),
  opacity: z.array(OpacityKeyframeV1Schema).max(32).default([]),
  effects: z.array(EffectKeyframeV1Schema).max(32).default([]),
  /**
   * The sixth channel, added in v2.
   *
   * Defaulted rather than required so documents stored before it existed keep parsing — the same
   * additive-field convention `anchor` and `animations` already rely on.
   */
  trim: z.array(TrimKeyframeV1Schema).max(32).default([]),
}).strict();

export const EMPTY_LAYER_ANIMATION = {
  position: [],
  scale: [],
  rotation: [],
  opacity: [],
  effects: [],
  trim: [],
} as const;

/**
 * The six channels a spec can write, named exactly as `LayerAnimationV1` keys.
 */
export const ANIMATION_CHANNELS = ["position", "scale", "rotation", "opacity", "effects", "trim"] as const;
export type AnimationChannel = (typeof ANIMATION_CHANNELS)[number];

/**
 * Every spec is expressed as a delay plus a duration, never an absolute timestamp.
 *
 * This is the whole point of the declarative layer: staggering eight layers is eight `delay`
 * values, not forty hand-computed `timeSeconds` values that the model has to keep consistent with
 * `durationSeconds` and the 128-keyframe budget.
 *
 * There is no `repeat` here on purpose. The cyclic specs already carry their own `cycles`/`bounces`
 * count, and a generic repeat would need a discontinuity at every cycle boundary that the
 * interpolator cannot express — two keyframes cannot share a timestamp.
 */
const SpecBaseSchema = z.object({
  delay: z.number().min(0).max(MAX_TIME_SECONDS).default(0),
  duration: z.number().min(0.05).max(MAX_TIME_SECONDS).default(0.5),
  easing: StickerEasingV1Schema.default("easeInOut"),
});

const DirectionSchema = z.enum(["up", "down", "left", "right"]);

export const AnimationSpecV1Schema = z.discriminatedUnion("type", [
  // --- entrances / exits -------------------------------------------------------------------
  SpecBaseSchema.extend({ type: z.literal("fadeIn") }).strict(),
  SpecBaseSchema.extend({ type: z.literal("fadeOut") }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("popIn"),
    /** Starting scale as a fraction of the layer's resting scale. */
    from: z.number().min(0.05).max(1).default(0.6),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("popOut"),
    to: z.number().min(0.05).max(1).default(0.6),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("slideIn"),
    direction: DirectionSchema,
    /** Offset from the resting position, in normalized canvas units. */
    distance: z.number().min(0.05).max(1).default(0.3),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("slideOut"),
    direction: DirectionSchema,
    distance: z.number().min(0.05).max(1).default(0.3),
  }).strict(),

  // --- absolute moves ----------------------------------------------------------------------
  SpecBaseSchema.extend({
    type: z.literal("moveTo"),
    x: z.number().min(-1).max(2),
    y: z.number().min(-1).max(2),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("scaleTo"),
    x: z.number().min(0.05).max(8),
    y: z.number().min(0.05).max(8),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("rotateTo"),
    degrees: z.number().min(-1080).max(1080),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("spin"),
    turns: z.number().min(0.25).max(3).default(1),
    direction: z.enum(["cw", "ccw"]).default("cw"),
  }).strict(),

  // --- cyclic ------------------------------------------------------------------------------
  SpecBaseSchema.extend({
    type: z.literal("wiggle"),
    amplitudeDegrees: z.number().min(1).max(45).default(8),
    cycles: z.number().int().min(1).max(8).default(3),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("pulse"),
    minScale: z.number().min(0.05).max(1).default(0.92),
    maxScale: z.number().min(1).max(4).default(1.08),
    cycles: z.number().int().min(1).max(8).default(3),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("bounce"),
    /** Peak height of the first hop, in normalized canvas units. Later hops decay. */
    height: z.number().min(0.02).max(0.5).default(0.12),
    bounces: z.number().int().min(1).max(6).default(2),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("float"),
    amplitude: z.number().min(0.01).max(0.3).default(0.04),
    cycles: z.number().int().min(1).max(8).default(2),
  }).strict(),

  // --- effects -----------------------------------------------------------------------------
  SpecBaseSchema.extend({
    type: z.literal("blurIn"),
    radius: z.number().min(0).max(20).default(8),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("blurOut"),
    radius: z.number().min(0).max(20).default(8),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("hueShift"),
    degrees: z.number().min(-180).max(180),
  }).strict(),

  // --- path drawing (v2) -------------------------------------------------------------------
  //
  // These write the `trim` channel and only mean anything on a layer that has a path: shapes with
  // a stroke, and SVG layers in vector render mode.
  SpecBaseSchema.extend({
    type: z.literal("drawOn"),
    /** Where the stroke starts from, as a fraction of its length. */
    from: z.number().min(0).max(1).default(0),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("drawOff"),
    to: z.number().min(0).max(1).default(1),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("trimTo"),
    start: z.number().min(0).max(1).default(0),
    end: z.number().min(0).max(1).default(1),
  }).strict(),
]);

export const AnimationSpecsV1Schema = z.array(AnimationSpecV1Schema).max(12);

export type AnimationSpecV1 = z.infer<typeof AnimationSpecV1Schema>;
export type AnimationSpecType = AnimationSpecV1["type"];
export type LayerAnimationV1 = z.infer<typeof LayerAnimationV1Schema>;
export type PositionKeyframeV1 = z.infer<typeof PositionKeyframeV1Schema>;
export type ScaleKeyframeV1 = z.infer<typeof ScaleKeyframeV1Schema>;
export type RotationKeyframeV1 = z.infer<typeof RotationKeyframeV1Schema>;
export type OpacityKeyframeV1 = z.infer<typeof OpacityKeyframeV1Schema>;
export type EffectKeyframeV1 = z.infer<typeof EffectKeyframeV1Schema>;
export type TrimKeyframeV1 = z.infer<typeof TrimKeyframeV1Schema>;

/**
 * Which channels each spec type writes.
 *
 * Two specs that write the same channel and overlap in time are rejected by the compiler rather
 * than merged: there is no sensible blend of "fade to 0" and "fade to 1" over the same instant, and
 * silently letting one win produces motion nobody asked for.
 */
export const SPEC_CHANNELS: Record<AnimationSpecType, readonly AnimationChannel[]> = {
  fadeIn: ["opacity"],
  fadeOut: ["opacity"],
  popIn: ["scale", "opacity"],
  popOut: ["scale", "opacity"],
  slideIn: ["position", "opacity"],
  slideOut: ["position", "opacity"],
  moveTo: ["position"],
  scaleTo: ["scale"],
  rotateTo: ["rotation"],
  spin: ["rotation"],
  wiggle: ["rotation"],
  pulse: ["scale"],
  bounce: ["position"],
  float: ["position"],
  blurIn: ["effects"],
  blurOut: ["effects"],
  hueShift: ["effects"],
  drawOn: ["trim"],
  drawOff: ["trim"],
  trimTo: ["trim"],
};

/** Specs sampled over a curve, whose sample density the budget allocator may reduce. */
export const CYCLIC_SPEC_TYPES = new Set<AnimationSpecType>(["wiggle", "pulse", "bounce", "float"]);

/** The resting state a layer returns to; supplied by the plan's layout. */
export type AnimationAnchorV1 = {
  position: { x: number; y: number };
  scale: { x: number; y: number };
  rotationDegrees: number;
  opacity: number;
  /**
   * Added in v2, alongside the trim channel.
   *
   * Required in the type even though the schema defaults it: on the wire a v1 anchor simply has no
   * `trim` key and picks up `{0, 1}`, but in code an anchor with an unstated resting window is a
   * value the compiler would have to guess at.
   */
  trim: { start: number; end: number };
};

/**
 * The resting state assumed when nothing says otherwise.
 *
 * These are exactly the values `StickerInterpolator` falls back to for an empty channel, which is
 * what lets the compiler skip emitting an anchor keyframe for an undisturbed channel.
 */
export const DEFAULT_ANCHOR: AnimationAnchorV1 = {
  position: { x: 0.5, y: 0.5 },
  scale: { x: 1, y: 1 },
  rotationDegrees: 0,
  opacity: 1,
  trim: { start: 0, end: 1 },
};

/** The resting trim of a layer that has never been trimmed: the whole path. */
export const DEFAULT_TRIM = { start: 0, end: 1 } as const;

/** An anchor's trim, tolerating a value decoded from a v1 payload that predates the field. */
export function anchorTrim(anchor: AnimationAnchorV1): { start: number; end: number } {
  return anchor.trim ?? DEFAULT_TRIM;
}

/** Total seconds a spec occupies, measured from t=0. */
export function specEndSeconds(spec: AnimationSpecV1): number {
  return spec.delay + spec.duration;
}
