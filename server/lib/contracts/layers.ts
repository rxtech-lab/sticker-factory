/**
 * The layer vocabulary a sticker document is built from.
 *
 * Split out of `./sticker` so the document module can stay about documents: what a layer *is* —
 * its resting anchor, the eight kinds, and what sits behind the stack — changes on its own
 * schedule from how documents are versioned, upcast, and mutated. The dependency runs one way,
 * `sticker -> layers`, and `./sticker` re-exports everything here so existing callers are
 * unaffected.
 */
import { z } from "zod";
import { SVGAnimationRigSchema } from "./controllable";
import { SpriteLayerFieldsV1, spriteLayerIssues } from "./sprite";
import {
  AnimationSpecV1Schema,
  DEFAULT_ANCHOR,
  EMPTY_LAYER_ANIMATION,
  LayerAnimationV1Schema,
  type LayerAnimationV1,
} from "@/lib/contracts/animation";
import {
  HexColorSchema,
  PaintSchema,
  ShapeKindSchema,
  StrokeSchema,
  SVGSourceSchema,
} from "@/lib/contracts/paint";

export const AssetIdSchema = z.string().uuid();
export const LayerIdSchema = z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/);

/**
 * The layer's resting state, from which declarative animations depart and to which they return.
 *
 * This is what `x`/`y`/`scale` in a plan become. It is stored rather than inferred because the
 * compiler has to be able to recompile a layer from its specs alone — reading the anchor back out
 * of already-compiled keyframes would be circular.
 */
export const LayerAnchorV1Schema = z.object({
  position: z.object({
    x: z.number().min(-1).max(2),
    y: z.number().min(-1).max(2),
  }).strict(),
  scale: z.object({
    x: z.number().min(0.05).max(8),
    y: z.number().min(0.05).max(8),
  }).strict(),
  rotationDegrees: z.number().min(-1080).max(1080),
  opacity: z.number().min(0).max(1),
  /**
   * The resting trim window, added in v2 alongside the trim channel.
   *
   * Defaulted rather than required so anchors stored before the field existed keep parsing — the
   * same additive convention `anchor` and `animations` themselves arrived under.
   */
  trim: z.object({
    start: z.number().min(0).max(1),
    end: z.number().min(0).max(1),
  }).strict().default({ start: 0, end: 1 }),
}).strict();

const LayerBaseSchema = z.object({
  id: LayerIdSchema,
  name: z.string().trim().min(1).max(80),
  hidden: z.boolean().default(false),
  anchor: LayerAnchorV1Schema.default(() => structuredClone(DEFAULT_ANCHOR)),
  /**
   * Declarative motion, authored as named effects with a delay and a duration.
   *
   * When non-empty this is the source of truth and `animation` below is its compiled output; the
   * document refinement asserts they agree. When empty, `animation` may hold hand-authored
   * keyframes and is left alone.
   */
  animations: z.array(AnimationSpecV1Schema).max(12).default([]),
  /**
   * Compiled keyframes. This is the only thing the renderer and exporter read.
   *
   * Defaulted from `EMPTY_LAYER_ANIMATION` rather than an inline literal so adding a channel — as
   * v2 did with `trim` — cannot leave this one behind.
   */
  animation: LayerAnimationV1Schema.default(() => structuredClone(EMPTY_LAYER_ANIMATION) as unknown as LayerAnimationV1),
  /** How this layer composites onto what is beneath it. Added in v2. */
  blendMode: z.enum([
    "normal", "multiply", "screen", "overlay", "softLight", "hardLight", "difference", "plusLighter",
  ]).default("normal"),
}).strict();

export const ImageLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("image"),
  assetId: AssetIdSchema,
  maskAssetId: AssetIdSchema.optional(),
  contentMode: z.enum(["fit", "fill"]).default("fit"),
}).strict();

export const TextLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("text"),
  text: z.string().min(1).max(160),
  font: z.enum(["rounded", "serif", "monospaced", "system"]),
  weight: z.enum(["regular", "medium", "semibold", "bold"]),
  /** v1 carried a bare hex `color` here; v2 takes a paint, so glyphs can hold a gradient. */
  paint: PaintSchema,
  alignment: z.enum(["leading", "center", "trailing"]).default("center"),
}).strict();

export const ShapeLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("shape"),
  /** v1 had five fixed names; v2 takes a parameterised kind, including free-form path data. */
  shape: ShapeKindSchema,
  fill: PaintSchema.optional(),
  stroke: StrokeSchema.optional(),
  cornerRadius: z.number().min(0).max(0.5).default(0.12),
}).strict().superRefine((layer, context) => {
  // A shape with neither fill nor stroke draws nothing at all, which is always an authoring bug
  // rather than a deliberately invisible layer — `hidden` already expresses that.
  if (!layer.fill && !layer.stroke) {
    context.addIssue({ code: "custom", message: `Shape layer ${layer.id} needs a fill or a stroke` });
  }
});

/**
 * Vector artwork, either embedded or referenced.
 *
 * Inline markup keeps a document self-contained, which is what makes an SVG layer free: unlike an
 * image layer it needs no asset round-trip and no generation. `asset` exists for artwork too large
 * to embed in a document that has to fit in a model's context window.
 */
export const SVGLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("svg"),
  rig: SVGAnimationRigSchema.optional(),
  svgState: z.record(z.string(), z.union([z.string(), z.boolean()])).optional(),
  posterAssetId: AssetIdSchema.optional(),
  source: SVGSourceSchema,
  /**
   * `native` renders the artwork through the SVG renderer directly: highest fidelity, but the
   * document is opaque, so trim and per-subpath tint do not apply. `vector` flattens it first,
   * which is what enables draw-on animation.
   */
  renderMode: z.enum(["native", "vector"]).default("vector"),
  tint: PaintSchema.optional(),
  strokeOverride: StrokeSchema.optional(),
  contentMode: z.enum(["fit", "fill"]).default("fit"),
  /** Seconds each successive subpath's trim window is offset by, so a glyph draws stroke by stroke. */
  staggerSeconds: z.number().min(0).max(4).default(0),
}).strict();

export const ParticleLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("particle"),
  preset: z.enum(["sparkles", "confetti", "hearts", "bubbles", "snow"]),
  count: z.number().int().min(1).max(64),
  /** Gradients collapse to their first stop here: a particle is one glyph, not a fillable area. */
  paint: PaintSchema,
  seed: z.number().int().min(0).max(2_147_483_647),
}).strict();

/**
 * Real frames the user captured, packed into one image and played back on the timeline.
 *
 * The frames arrive as a single transparent PNG holding a `rows` x `columns` grid of equally sized
 * tiles — a sprite sheet — rather than as an animated WebP, GIF, APNG, or MP4. That choice buys
 * three things at once: no new decode path anywhere (sharp reads it as an ordinary one-page PNG,
 * `CGImage.cropping(to:)` slices it for free on device), and the vision model can *see* the motion,
 * because a contact sheet is exactly what it can read and an animated file is exactly what it
 * cannot. `lib/render/sticker-render.ts` already relies on that second fact in the other direction.
 *
 * `frameRate` is the footage's own rate and is independent of the document's `fps`, which governs
 * how densely the exporter samples the timeline. See `sequenceFrameIndex` for how the two compose.
 */
export const SequenceLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("sequence"),
  /** The frame-atlas PNG. One asset, whatever the frame count. */
  assetId: AssetIdSchema,
  columns: z.number().int().min(1).max(8),
  rows: z.number().int().min(1).max(8),
  /** Tiles actually used, read row-major from the top-left. Trailing cells of the grid may be empty. */
  frameCount: z.number().int().min(1).max(64),
  /** The captured footage's own playback rate, in frames per second. */
  frameRate: z.number().min(1).max(60),
  /** How the footage repeats *within* the layer. Independent of the document's `loop`. */
  playback: z.enum(["loop", "once", "pingPong"]).default("loop"),
  /** When on the document timeline the first tile appears. Before it, the first tile is held. */
  startSeconds: z.number().min(0).max(30).default(0),
  contentMode: z.enum(["fit", "fill"]).default("fit"),
  /**
   * Tile 0, extracted to its own asset so a client that predates v3 can be served a still.
   *
   * Optional because the layer is valid without it — a document authored on device has no poster
   * until the server derives one — but `downcastForClient` can only degrade layers that have it.
   */
  posterAssetId: AssetIdSchema.optional(),
}).strict().superRefine((layer, context) => {
  if (layer.frameCount > layer.rows * layer.columns) {
    context.addIssue({
      code: "custom",
      message: `Sequence layer ${layer.id} declares ${layer.frameCount} frames but its `
        + `${layer.rows}x${layer.columns} grid holds only ${layer.rows * layer.columns}`,
    });
  }
});

/**
 * A short generated clip of the whole subject, played back on the timeline like captured footage.
 *
 * The clip is an opaque 1:1 MP4 shot against a solid chroma backdrop — the video models cannot
 * render alpha any more than the quick image model can — and the *client* keys that backdrop out
 * at render time, with the same dominance-and-despill rule `lib/ai/chroma-key.ts` applies to quick
 * images on the server. The server never decodes it: everything that draws a document here — the
 * layout review, quick publish, the marketplace stills, and `downcastForClient` — draws
 * `posterAssetId` instead, which is the keyed transparent still the clip was animated from. That is
 * why the poster is required where a sequence layer's is optional.
 *
 * `frameCount` and `frameRate` are read out of the file by `inspectMp4` when the asset is stored
 * and copied onto the layer, so the renderer can pick a frame for a document time without opening
 * the container first. `videoFrameIndex` composes them with the document's `fps` the way
 * `sequenceFrameIndex` does for an atlas.
 */
export const VideoLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("video"),
  /** The MP4 (`assets.kind === "video"`). */
  assetId: AssetIdSchema,
  /** Which backdrop the clip was shot against, so the client knows what to key. */
  keyColor: z.enum(["green", "blue"]),
  frameCount: z.number().int().min(1).max(600),
  /** The clip's own playback rate, in frames per second. */
  frameRate: z.number().min(1).max(60),
  /** How the clip repeats *within* the layer. Independent of the document's `loop`. */
  playback: z.enum(["loop", "once", "pingPong"]).default("loop"),
  /** When on the document timeline the first frame appears. Before it, the first frame is held. */
  startSeconds: z.number().min(0).max(30).default(0),
  contentMode: z.enum(["fit", "fill"]).default("fit"),
  /** The keyed transparent still the clip was animated from. Required; see above. */
  posterAssetId: AssetIdSchema,
}).strict();

/**
 * A controllable character: body clips and face expressions that compose at draw time.
 *
 * This is the layer a configurable sticker's mood and pose controls act on. `clipId` picks which
 * sheet of body frames plays and `expressionId` picks which face is drawn into every frame's slot,
 * so a mood and a pose are independent choices rather than a table of pre-drawn combinations. The
 * renderer draws the body cell, then the expression tile centred on that frame's face slot;
 * `SpriteFrameCache` on iOS and `compositeSpriteFrame` on the server are the two implementations
 * and a pixel test pins each. The fields and the helpers live in `./sprite`.
 */
export const SpriteLayerV1Schema = LayerBaseSchema.extend(SpriteLayerFieldsV1).strict().superRefine((layer, context) => {
  for (const message of spriteLayerIssues(layer)) context.addIssue({ code: "custom", message });
});

export type SpriteLayerV1 = z.infer<typeof SpriteLayerV1Schema>;
export { spriteClip, spriteExpressionTile } from "./sprite";
export type { SpriteClipV1, SpriteExpressionTileV1, SpriteFrameV1 } from "./sprite";

/**
 * The v2 layer union, frozen so v2 documents keep parsing as v2.
 *
 * It shares the five layer schemas by reference rather than snapshotting them, which is sound only
 * because v3's change is purely additive. Anything that later *alters* one of those five must
 * snapshot this union first, exactly as `LegacyLayerV1Schema` below is a full copy.
 */
export const LegacyStickerLayerV2Schema = z.union([
  ImageLayerV1Schema,
  TextLayerV1Schema,
  ShapeLayerV1Schema,
  SVGLayerV1Schema,
  ParticleLayerV1Schema,
]);

/** The v3 layer union, frozen the same way and for the same reason: v4 only adds `video`. */
export const LegacyStickerLayerV3Schema = z.union([
  ImageLayerV1Schema,
  TextLayerV1Schema,
  ShapeLayerV1Schema,
  SVGLayerV1Schema,
  ParticleLayerV1Schema,
  SequenceLayerV1Schema,
]);

/** The v4 layer union, frozen the same way: v5 only adds `sprite` (and `configuration`). */
export const LegacyStickerLayerV4Schema = z.union([ImageLayerV1Schema, TextLayerV1Schema, ShapeLayerV1Schema, SVGLayerV1Schema, ParticleLayerV1Schema, SequenceLayerV1Schema, VideoLayerV1Schema]);

export const StickerLayerV1Schema = z.union([
  ImageLayerV1Schema,
  TextLayerV1Schema,
  // Not a `discriminatedUnion` any more: `ShapeLayerV1Schema` carries a `superRefine`, which wraps
  // it in an effect that zod's discriminated union cannot see a literal `type` through.
  ShapeLayerV1Schema,
  SVGLayerV1Schema,
  ParticleLayerV1Schema,
  SequenceLayerV1Schema,
  VideoLayerV1Schema,
  SpriteLayerV1Schema,
]);

export const Mp4BackgroundV1Schema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("solid"), color: HexColorSchema }).strict(),
  z.object({
    type: z.literal("linearGradient"),
    colors: z.tuple([HexColorSchema, HexColorSchema]),
    angleDegrees: z.number().min(0).max(360),
  }).strict(),
]);

/**
 * What sits behind the layer stack.
 *
 * Two of these live on a document and they are not interchangeable. `background` is part of the
 * artwork and renders into every output including the transparent ones, which is why it defaults to
 * `none` — a sticker is transparent unless its author says otherwise. `mp4Background` only fills
 * the alpha when a format cannot carry it.
 */
export const BackgroundSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("none") }).strict(),
  z.object({ type: z.literal("solid"), color: HexColorSchema }).strict(),
  z.object({
    type: z.literal("linearGradient"),
    stops: z.array(z.object({ color: HexColorSchema, location: z.number().min(0).max(1) }).strict()).min(2).max(8),
    angleDegrees: z.number().min(-360).max(360).default(0),
  }).strict(),
  z.object({
    type: z.literal("radialGradient"),
    stops: z.array(z.object({ color: HexColorSchema, location: z.number().min(0).max(1) }).strict()).min(2).max(8),
    center: z.object({ x: z.number().min(-1).max(2), y: z.number().min(-1).max(2) }).strict()
      .default({ x: 0.5, y: 0.5 }),
    radius: z.number().min(0.01).max(4).default(0.5),
  }).strict(),
  z.object({ type: z.literal("image"), assetId: AssetIdSchema, contentMode: z.enum(["fit", "fill"]).default("fill") }).strict(),
]);
