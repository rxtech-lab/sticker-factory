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

/**
 * A directional band-pass over the layer's alpha, driving wipe reveals.
 *
 * The layer is visible where its coordinate along the axis at `angleDegrees` falls inside
 * `start...end`, with `softness` feathering both edges. Unlike `trim` — which sweeps along a
 * *path's arc length* and so only means anything on a stroked shape or an SVG — this is spatial and
 * applies to every layer kind, including images and text.
 *
 * `angleDegrees` follows the same convention as `AnimatedPaint.linearGradient`: 0° runs
 * left-to-right and angles increase clockwise. Identity is `{start: 0, end: 1, softness: 0}`, which
 * is what an empty channel means.
 */
export const WipeKeyframeV1Schema = KeyframeBaseSchema.extend({
  start: z.number().min(0).max(1).default(0),
  end: z.number().min(0).max(1).default(1),
  angleDegrees: z.number().min(-360).max(360).default(0),
  softness: z.number().min(0).max(0.5).default(0),
}).strict();

/**
 * A travelling highlight band — the "light sweep" that reads as a specular glint.
 *
 * `position` is the band's *centre* along the axis at `angleDegrees`, so the band is fully
 * off-canvas at `-width / 2` and again at `1 + width / 2`. The range is the position channel's
 * `-1...2` rather than `0...1` precisely so those two extremes are representable: clamping to
 * `0...1` would silently pin a sweep's opening keyframe to the layer's leading edge.
 *
 * Identity is `intensity: 0` — the band is always somewhere, it is just invisible.
 */
export const SheenKeyframeV1Schema = KeyframeBaseSchema.extend({
  position: z.number().min(-1).max(2).default(0),
  width: z.number().min(0.02).max(1).default(0.25),
  angleDegrees: z.number().min(-360).max(360).default(0),
  intensity: z.number().min(0).max(1).default(0),
}).strict();

/**
 * Glow / light bleed: a blurred additive copy of the layer sitting under the crisp one.
 *
 * Distinct from `effects.blurRadius`, which blurs the layer *instead of* showing it. Here the layer
 * stays sharp and grows a halo, so it reads as brightness rather than defocus — which is why this is
 * its own channel and not another field on `effects`: `blurOut` while blooming is a good-looking
 * combination that a shared channel would reject as a conflict.
 *
 * `radius` is a fraction of the layer's box width, so a bloom means the same thing at any canvas
 * size. There is no tint: the halo is the layer's own pixels, which is both free and the physically
 * right answer. Identity is `amount: 0`.
 */
export const GlowKeyframeV1Schema = KeyframeBaseSchema.extend({
  amount: z.number().min(0).max(1).default(0),
  radius: z.number().min(0.01).max(0.5).default(0.08),
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
  /**
   * Channels seven through nine, added in v3 for wipe, light-sweep, and bloom.
   *
   * Three separate channels rather than one shared "compositing" channel because the compiler
   * rejects two specs that drive the same channel over overlapping windows. Merging them would make
   * `wipeIn` + `shine` (whose `angleDegrees` usually differ) and `blurOut` + `bloomIn` unauthorable.
   *
   * Same additive defaulting as `trim`: a document stored before these existed still parses.
   */
  wipe: z.array(WipeKeyframeV1Schema).max(32).default([]),
  sheen: z.array(SheenKeyframeV1Schema).max(32).default([]),
  glow: z.array(GlowKeyframeV1Schema).max(32).default([]),
}).strict();

export const EMPTY_LAYER_ANIMATION = {
  position: [],
  scale: [],
  rotation: [],
  opacity: [],
  effects: [],
  trim: [],
  wipe: [],
  sheen: [],
  glow: [],
} as const;

/**
 * The nine channels a spec can write, named exactly as `LayerAnimationV1` keys.
 */
export const ANIMATION_CHANNELS = [
  "position",
  "scale",
  "rotation",
  "opacity",
  "effects",
  "trim",
  "wipe",
  "sheen",
  "glow",
] as const;
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
  /**
   * A curved move: the layer travels to `x`/`y` along a parabolic arc rather than a straight line.
   *
   * `moveTo` interpolates two keyframes, which is a straight line by construction — there is no
   * amount of easing that bends it, so a throw, a lob, or an orbiting sweep was previously
   * inexpressible. This samples a quadratic Bézier into position keyframes instead, which is the
   * only way to curve a channel the interpolator blends linearly.
   */
  SpecBaseSchema.extend({
    type: z.literal("arcTo"),
    x: z.number().min(-1).max(2),
    y: z.number().min(-1).max(2),
    /**
     * How far the path bows away from the straight line, at its midpoint, in normalized units.
     *
     * Measured perpendicular to the direction of travel and signed so that positive always bows
     * toward the top of the canvas — a rightward and a leftward throw with the same `arcHeight`
     * both arc over, not mirrored. `0` degenerates to exactly the straight line `moveTo` draws.
     */
    arcHeight: z.number().min(-1).max(1).default(0.25),
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

  // --- spatial wipes (v3) ------------------------------------------------------------------
  //
  // Unlike the trim specs above, these work on every layer kind: they mask the layer's alpha along a
  // spatial axis rather than sweeping a path's length.
  SpecBaseSchema.extend({
    type: z.literal("wipeIn"),
    /** The direction the reveal travels, so `right` uncovers the layer from its left edge. */
    direction: DirectionSchema,
    /** Feathering at the wipe edge, as a fraction of the layer. `0` is a hard edge. */
    softness: z.number().min(0).max(0.5).default(0),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("wipeOut"),
    direction: DirectionSchema,
    softness: z.number().min(0).max(0.5).default(0),
  }).strict(),
  /** The general form, for angled wipes and barn-door reveals a direction cannot express. */
  SpecBaseSchema.extend({
    type: z.literal("wipeTo"),
    start: z.number().min(0).max(1).default(0),
    end: z.number().min(0).max(1).default(1),
    angleDegrees: z.number().min(-360).max(360).default(0),
    softness: z.number().min(0).max(0.5).default(0),
  }).strict(),

  // --- light (v3) --------------------------------------------------------------------------
  /**
   * A highlight band sweeping across the layer, like light catching a glossy surface.
   *
   * `easing` is ignored: the band must travel at constant speed or it reads as a stutter. Repeats
   * are a `cycles` count rather than several specs, because two `shine` specs whose windows merely
   * touch would put two different band positions on one timestamp and be rejected.
   */
  SpecBaseSchema.extend({
    type: z.literal("shine"),
    /** The sweep axis. The default rakes slightly upward, which is what reads as a gloss. */
    angleDegrees: z.number().min(-360).max(360).default(-30),
    width: z.number().min(0.02).max(1).default(0.25),
    intensity: z.number().min(0).max(1).default(0.6),
    cycles: z.number().int().min(1).max(4).default(1),
  }).strict(),
  /**
   * Glow / light bleed. The layer stays sharp and grows a halo of its own colours.
   *
   * `radius` is a fraction of the layer's box width. Distinct from `blurIn`/`blurOut`, which drive
   * the `effects` channel and defocus the layer itself — the two compose.
   */
  SpecBaseSchema.extend({
    type: z.literal("bloomIn"),
    radius: z.number().min(0.01).max(0.5).default(0.08),
    intensity: z.number().min(0).max(1).default(0.7),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("bloomOut"),
    radius: z.number().min(0.01).max(0.5).default(0.08),
    intensity: z.number().min(0).max(1).default(0.7),
  }).strict(),
  SpecBaseSchema.extend({
    type: z.literal("bloomPulse"),
    radius: z.number().min(0.01).max(0.5).default(0.08),
    intensity: z.number().min(0).max(1).default(0.7),
    cycles: z.number().int().min(1).max(8).default(2),
  }).strict(),
]);

export const AnimationSpecsV1Schema = z.array(AnimationSpecV1Schema).max(12);

export type StickerEasingV1 = z.infer<typeof StickerEasingV1Schema>;

export type AnimationSpecV1 = z.infer<typeof AnimationSpecV1Schema>;
export type AnimationSpecType = AnimationSpecV1["type"];
export type LayerAnimationV1 = z.infer<typeof LayerAnimationV1Schema>;
export type PositionKeyframeV1 = z.infer<typeof PositionKeyframeV1Schema>;
export type ScaleKeyframeV1 = z.infer<typeof ScaleKeyframeV1Schema>;
export type RotationKeyframeV1 = z.infer<typeof RotationKeyframeV1Schema>;
export type OpacityKeyframeV1 = z.infer<typeof OpacityKeyframeV1Schema>;
export type EffectKeyframeV1 = z.infer<typeof EffectKeyframeV1Schema>;
export type TrimKeyframeV1 = z.infer<typeof TrimKeyframeV1Schema>;
export type WipeKeyframeV1 = z.infer<typeof WipeKeyframeV1Schema>;
export type SheenKeyframeV1 = z.infer<typeof SheenKeyframeV1Schema>;
export type GlowKeyframeV1 = z.infer<typeof GlowKeyframeV1Schema>;

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
  arcTo: ["position"],
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
  wipeIn: ["wipe"],
  wipeOut: ["wipe"],
  wipeTo: ["wipe"],
  shine: ["sheen"],
  bloomIn: ["glow"],
  bloomOut: ["glow"],
  bloomPulse: ["glow"],
};

/** Specs sampled over a curve, whose sample density the budget allocator may reduce. */
export const CYCLIC_SPEC_TYPES = new Set<AnimationSpecType>([
  "wiggle", "pulse", "bounce", "float", "shine", "bloomPulse",
]);

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
