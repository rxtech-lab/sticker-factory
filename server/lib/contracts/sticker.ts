import { z } from "zod";
import { compileLayerAnimation, countKeyframes, type AnimationTiming } from "@/lib/animation/compile";
import {
  ANIMATION_CHANNELS,
  AnimationSpecV1Schema,
  DEFAULT_ANCHOR,
  EMPTY_LAYER_ANIMATION,
  EffectKeyframeV1Schema,
  GlowKeyframeV1Schema,
  LayerAnimationV1Schema,
  OpacityKeyframeV1Schema,
  PositionKeyframeV1Schema,
  RotationKeyframeV1Schema,
  ScaleKeyframeV1Schema,
  SheenKeyframeV1Schema,
  StickerEasingV1Schema,
  TrimKeyframeV1Schema,
  WipeKeyframeV1Schema,
  type LayerAnimationV1,
} from "@/lib/contracts/animation";
import {
  HexColorSchema,
  PaintSchema,
  ShapeKindSchema,
  StrokeSchema,
  SVGSourceSchema,
  type PaintV2,
} from "@/lib/contracts/paint";

export {
  AnimationSpecV1Schema,
  EffectKeyframeV1Schema,
  LayerAnimationV1Schema,
  OpacityKeyframeV1Schema,
  PositionKeyframeV1Schema,
  RotationKeyframeV1Schema,
  ScaleKeyframeV1Schema,
  StickerEasingV1Schema,
};
export type { AnimationSpecV1, LayerAnimationV1 } from "@/lib/contracts/animation";
export * from "@/lib/contracts/paint";

const AssetIdSchema = z.string().uuid();
export const LayerIdSchema = z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/);

/**
 * The document version this module writes. Anything older is upcast on read.
 *
 * v3 adds the `sequence` layer: real frames lifted from a Live Photo, packed into one image. It is
 * purely additive — every v2 document is a valid v3 document with a different stamp — which is why
 * `upcastV2ToV3` is a one-line rewrite. Bumping this is not free on the client, though: a shipped
 * iOS build throws on an unknown layer `type` and cannot open the project at all, so v3 documents
 * are downcast for clients that do not announce support. See `downcastForClient`.
 */
export const CURRENT_DOCUMENT_VERSION = 3;

/**
 * How big a stored document may get, serialized.
 *
 * Needed because v2 layers can carry inline SVG: twelve layers at the 200 KB per-layer markup cap
 * is 2.4 MB, which no route could accept — `readJson` stops at 1 MB, and the whole body is also
 * hashed into the idempotency key and stored in its response row. Bounding the document is what
 * keeps all three honest, and the editor surfaces the same limit while authoring.
 */
export const MAX_DOCUMENT_BYTES = 512 * 1024;

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
 * The v2 layer union, frozen so v2 documents keep parsing as v2.
 *
 * It shares the five layer schemas by reference rather than snapshotting them, which is sound only
 * because v3's change is purely additive. Anything that later *alters* one of those five must
 * snapshot this union first, exactly as `LegacyLayerV1Schema` below is a full copy.
 */
const LegacyStickerLayerV2Schema = z.union([
  ImageLayerV1Schema,
  TextLayerV1Schema,
  ShapeLayerV1Schema,
  SVGLayerV1Schema,
  ParticleLayerV1Schema,
]);

export const StickerLayerV1Schema = z.union([
  ImageLayerV1Schema,
  TextLayerV1Schema,
  // Not a `discriminatedUnion` any more: `ShapeLayerV1Schema` carries a `superRefine`, which wraps
  // it in an effect that zod's discriminated union cannot see a literal `type` through.
  ShapeLayerV1Schema,
  SVGLayerV1Schema,
  ParticleLayerV1Schema,
  SequenceLayerV1Schema,
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

export const CANVAS_MIN_DIMENSION = 16;
export const CANVAS_MAX_DIMENSION = 4096;

const DocumentBaseSchema = z.object({
  version: z.literal(CURRENT_DOCUMENT_VERSION),
  canvas: z.object({
    // v1 pinned this to exactly 1024x1024. It is a validated range in v2 so one engine can drive a
    // 64pt toolbar glyph and a 2048px export without a second contract.
    width: z.number().int().min(CANVAS_MIN_DIMENSION).max(CANVAS_MAX_DIMENSION),
    height: z.number().int().min(CANVAS_MIN_DIMENSION).max(CANVAS_MAX_DIMENSION),
    coordinateSpace: z.literal("normalized"),
    transparent: z.boolean().default(true),
  }).strict(),
  // Deliberately unbounded. The cap used to be a fixed count, which turned "add one more layer" into
  // a hard failure — after the image for that layer had already been generated and paid for. Nothing
  // downstream is written against a layer count; rendering, export, and the operation log are all
  // linear in it, so the request body limit is the only bound that needs to exist.
  layers: z.array(StickerLayerV1Schema),
  background: BackgroundSchema.default({ type: "none" }),
  mp4Background: Mp4BackgroundV1Schema.default({ type: "solid", color: "#FFFFFF" }),
}).strict();

const StaticDocumentV1Schema = DocumentBaseSchema.extend({
  kind: z.literal("static"),
  durationSeconds: z.literal(0),
  fps: z.literal(0),
  loop: z.literal("once"),
  speed: z.literal(1).default(1),
}).strict();

const AnimatedDocumentV1Schema = DocumentBaseSchema.extend({
  kind: z.literal("animated"),
  durationSeconds: z.number().min(0.1).max(30).default(2),
  fps: z.number().int().min(1).max(60).default(30),
  loop: z.enum(["once", "loop", "pingPong"]).default("loop"),
  /**
   * A playback multiplier. It never touches keyframe times — it divides elapsed time on the way
   * into the interpolator — which is what lets speed change without recompiling, and what lets the
   * same compiled document be exported at two different speeds.
   */
  speed: z.number().min(0.1).max(8).default(1),
}).strict();

/**
 * Stillness held on an exported sticker's last frame before it repeats.
 *
 * Not part of the document: it describes the file that gets shared, not the sticker being designed,
 * so a revision's timing still means its motion and nothing else. It lives in the contracts module
 * because both the export validator and the upload inspector need it and neither may import the
 * other. `loopHoldSeconds` in `StickerGeniOS/Rendering/StickerExporter.swift` writes it and must
 * carry the same number.
 */
export const EXPORT_LOOP_HOLD_SECONDS = 0.6;

/**
 * The longest an accepted rendition may run: a ping-ponged 4s document is an 8s cycle, plus the
 * hold that gets appended to it.
 */
export const MAX_RENDITION_SECONDS = 8 + EXPORT_LOOP_HOLD_SECONDS;

function keyframeCount(layer: z.infer<typeof StickerLayerV1Schema>): number {
  return countKeyframes(layer.animation);
}

/** Key-order-independent structural comparison, since zod and the compiler build objects differently. */
function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

/**
 * The v1 document, kept solely so stored rows keep parsing.
 *
 * `document_json` is immutable after insert — a SQL trigger enforces it — so existing revisions
 * stay v1 forever and cannot be backfilled. This is therefore permanent code, not a migration
 * step, and `upcastV1ToV2` runs on every read of an old row for the lifetime of the table.
 */
const LegacyLayerBaseV1Schema = z.object({
  id: LayerIdSchema,
  name: z.string().trim().min(1).max(80),
  hidden: z.boolean().default(false),
  anchor: LayerAnchorV1Schema.default(() => structuredClone(DEFAULT_ANCHOR)),
  animations: z.array(AnimationSpecV1Schema).max(12).default([]),
  animation: LayerAnimationV1Schema.default(() => structuredClone(EMPTY_LAYER_ANIMATION) as unknown as LayerAnimationV1),
}).strict();

const LegacyLayerV1Schema = z.discriminatedUnion("type", [
  LegacyLayerBaseV1Schema.extend({
    type: z.literal("image"),
    assetId: AssetIdSchema,
    maskAssetId: AssetIdSchema.optional(),
    contentMode: z.enum(["fit", "fill"]).default("fit"),
  }).strict(),
  LegacyLayerBaseV1Schema.extend({
    type: z.literal("text"),
    text: z.string().min(1).max(160),
    font: z.enum(["rounded", "serif", "monospaced", "system"]),
    weight: z.enum(["regular", "medium", "semibold", "bold"]),
    color: HexColorSchema,
    alignment: z.enum(["leading", "center", "trailing"]).default("center"),
  }).strict(),
  LegacyLayerBaseV1Schema.extend({
    type: z.literal("shape"),
    shape: z.enum(["circle", "roundedRectangle", "star", "heart", "burst"]),
    fill: HexColorSchema,
    stroke: HexColorSchema.optional(),
    strokeWidth: z.number().min(0).max(0.08).default(0),
    cornerRadius: z.number().min(0).max(0.5).default(0.12),
  }).strict(),
  LegacyLayerBaseV1Schema.extend({
    type: z.literal("particle"),
    preset: z.enum(["sparkles", "confetti", "hearts", "bubbles", "snow"]),
    count: z.number().int().min(1).max(64),
    color: HexColorSchema,
    seed: z.number().int().min(0).max(2_147_483_647),
  }).strict(),
]);

const LegacyDocumentBaseV1Schema = z.object({
  version: z.literal(1),
  canvas: z.object({
    width: z.literal(1024),
    height: z.literal(1024),
    coordinateSpace: z.literal("normalized"),
    transparent: z.literal(true),
  }).strict(),
  layers: z.array(LegacyLayerV1Schema).max(8),
  mp4Background: Mp4BackgroundV1Schema.default({ type: "solid", color: "#FFFFFF" }),
}).strict();

export const LegacyStickerDocumentV1Schema = z.discriminatedUnion("kind", [
  LegacyDocumentBaseV1Schema.extend({
    kind: z.literal("static"),
    durationSeconds: z.literal(0),
    fps: z.literal(0),
    loop: z.literal("once"),
  }).strict(),
  LegacyDocumentBaseV1Schema.extend({
    kind: z.literal("animated"),
    durationSeconds: z.number().min(0.5).max(4).default(2),
    fps: z.number().int().min(1).max(30).default(30),
    loop: z.enum(["once", "loop", "pingPong"]).default("loop"),
  }).strict(),
]);

/**
 * Rewrites a v1 document into the v2 shape.
 *
 * Must be total: `getSticker` re-parses *every* revision of a sticker on read, so one row that
 * fails to upcast would 500 the whole detail endpoint rather than degrading that one revision.
 * Every v1 value has an exact v2 counterpart, so nothing here is lossy — the widening only ever
 * adds expressiveness the old shape did not have.
 */
export function upcastV1ToV2(document: z.infer<typeof LegacyStickerDocumentV1Schema>): unknown {
  const solid = (color: string): PaintV2 => ({ type: "solid", color });
  return {
    ...document,
    // The literal 2, *not* `CURRENT_DOCUMENT_VERSION`. This function's output is piped straight into
    // the v2 schema, so stamping it with whatever version happens to be current today would break
    // the chain the moment the document version is bumped again.
    version: 2,
    canvas: { ...document.canvas, transparent: true },
    background: { type: "none" },
    speed: 1,
    layers: document.layers.map((layer) => {
      const base = { ...layer, blendMode: "normal" as const };
      switch (layer.type) {
      case "text": {
        const { color, ...rest } = base as typeof base & { color: string };
        return { ...rest, paint: solid(color) };
      }
      case "particle": {
        const { color, ...rest } = base as typeof base & { color: string };
        return { ...rest, paint: solid(color) };
      }
      case "shape": {
        const shape = base as typeof base & {
          shape: string; fill: string; stroke?: string; strokeWidth: number;
        };
        const { fill, stroke, strokeWidth, shape: kind, ...rest } = shape;
        return {
          ...rest,
          // v1's five names map onto v2's parameterised kinds; `star` picks up the five-point
          // default that v1 hard-coded.
          shape: kind === "star" ? { kind: "star", points: 5, innerRatio: 0.42 } : { kind },
          fill: solid(fill),
          // v1 stored a colour and a width separately, and a zero width meant "no stroke".
          stroke: stroke && strokeWidth > 0
            ? { paint: solid(stroke), width: strokeWidth, lineCap: "round", lineJoin: "round", dash: [] }
            : undefined,
        };
      }
      default:
        return base;
      }
    }),
  };
}

/**
 * The v2 document, kept for the same reason the v1 one is: stored rows never change.
 *
 * v2 is v3 with an older stamp and a layer union that has no `sequence` in it. Expressing it as a
 * narrowing of the current base rather than as a copy is safe here because v3 added a layer and
 * changed nothing else; see the note on `LegacyStickerLayerV2Schema`.
 */
const LegacyDocumentBaseV2Schema = DocumentBaseSchema.extend({
  version: z.literal(2),
  layers: z.array(LegacyStickerLayerV2Schema),
});

export const LegacyStickerDocumentV2Schema = z.discriminatedUnion("kind", [
  LegacyDocumentBaseV2Schema.extend({
    kind: z.literal("static"),
    durationSeconds: z.literal(0),
    fps: z.literal(0),
    loop: z.literal("once"),
    speed: z.literal(1).default(1),
  }).strict(),
  LegacyDocumentBaseV2Schema.extend({
    kind: z.literal("animated"),
    durationSeconds: z.number().min(0.1).max(30).default(2),
    fps: z.number().int().min(1).max(60).default(30),
    loop: z.enum(["once", "loop", "pingPong"]).default("loop"),
    speed: z.number().min(0.1).max(8).default(1),
  }).strict(),
]);

/**
 * Rewrites a v2 document into the v3 shape.
 *
 * Total and lossless by construction: v3 only widens the layer union, so every v2 value is already
 * a v3 value and the version stamp is the only thing that moves.
 */
export function upcastV2ToV3(document: z.infer<typeof LegacyStickerDocumentV2Schema>): unknown {
  return { ...document, version: 3 };
}

/**
 * The oldest document version a client may ask for. Anything below this is not a client we ever
 * shipped, so a header claiming it is treated as the floor rather than honoured.
 */
export const MIN_CLIENT_DOCUMENT_VERSION = 2;

/**
 * Rewrites a document into the shape a given client can actually decode.
 *
 * This exists because bumping the document version is not free on a shipped app. iOS decodes a
 * layer's `type` into a closed enum, so a build that predates `sequence` throws on it — and that
 * throw fails the layer, then the document, then the whole sticker payload, leaving the user with a
 * project they cannot open at all. Builds already in the field cannot be fixed after the fact.
 *
 * So a client that does not announce v3 support gets each sequence layer replaced by an ordinary
 * image layer showing the capture's poster frame, and the document restamped as v2. Everything else
 * about the layer — its id, name, anchor, animations, compiled keyframes, blend mode — is carried
 * across unchanged, so the sticker still moves exactly as the AI authored it. What that client
 * loses is the real footage, not the sticker.
 *
 * A sequence layer with no poster is dropped rather than degraded: an image layer pointing at an
 * atlas would render the whole sprite sheet at once, which looks like a rendering fault. Dropping
 * is honest, and the poster is derived whenever the server writes such a document.
 *
 * Applied on read, never on write. The stored row stays canonical v3 so a client that *can* read it
 * still gets the footage.
 */
export function downcastForClient(document: StickerDocument, clientVersion: number): unknown {
  if (clientVersion >= CURRENT_DOCUMENT_VERSION) return document;

  const layers = document.layers.flatMap((layer) => {
    if (layer.type !== "sequence") return [layer];
    if (!layer.posterAssetId) return [];
    const { columns, rows, frameCount, frameRate, playback, startSeconds, posterAssetId, type, assetId, ...base } = layer;
    void columns; void rows; void frameCount; void frameRate; void playback; void startSeconds; void type; void assetId;
    return [{ ...base, type: "image" as const, assetId: posterAssetId }];
  });

  return { ...document, version: MIN_CLIENT_DOCUMENT_VERSION, layers };
}

/**
 * The document version a request announces support for, from its `X-Sticker-Contract` header.
 *
 * Absent means a client built before the header existed, which is exactly the population the
 * downcast is for — so the default is the floor, not the current version. An unparseable or
 * out-of-range value is treated the same way, because guessing generously is the one failure mode
 * that bricks a project.
 */
export const CLIENT_CONTRACT_HEADER = "x-sticker-contract";

export function clientDocumentVersion(request: { headers: { get(name: string): string | null } }): number {
  const raw = Number(request.headers.get(CLIENT_CONTRACT_HEADER));
  if (!Number.isInteger(raw)) return MIN_CLIENT_DOCUMENT_VERSION;
  return Math.min(Math.max(raw, MIN_CLIENT_DOCUMENT_VERSION), CURRENT_DOCUMENT_VERSION);
}

const CurrentDocumentSchema = z.discriminatedUnion("kind", [
  StaticDocumentV1Schema,
  AnimatedDocumentV1Schema,
]);

/**
 * The document contract every caller should use.
 *
 * Accepts any stored version on the way in and always produces the current one, so the upcasts live
 * in exactly one place and nothing downstream has to know which shape a row was stored in. The
 * v1 branch chains through v2 rather than jumping straight to v3, so each upcast stays a single
 * hop and only ever has to know about the version immediately after it.
 */
export const StickerDocumentSchema = z.union([
  CurrentDocumentSchema,
  LegacyStickerDocumentV2Schema.transform(upcastV2ToV3).pipe(CurrentDocumentSchema),
  LegacyStickerDocumentV1Schema.transform(upcastV1ToV2)
    .pipe(LegacyStickerDocumentV2Schema).transform(upcastV2ToV3).pipe(CurrentDocumentSchema),
]).superRefine((document, context) => {
  const layerIds = new Set<string>();
  let totalKeyframes = 0;
  const timing: AnimationTiming = { kind: document.kind, durationSeconds: document.durationSeconds };

  for (const layer of document.layers) {
    if (layerIds.has(layer.id)) {
      context.addIssue({ code: "custom", message: `Duplicate layer id: ${layer.id}` });
    }
    layerIds.add(layer.id);
    totalKeyframes += keyframeCount(layer);

    if (layer.type === "sequence") {
      // A still document has no timeline to walk, so multi-frame footage in one could only ever
      // show its first tile. Saying so here beats silently rendering 1 of 12.
      if (document.kind === "static" && layer.frameCount !== 1) {
        context.addIssue({
          code: "custom",
          message: `Sequence layer ${layer.id} has ${layer.frameCount} frames in a static document, `
            + "which can only ever show the first. Make the document animated or trim the footage to one frame.",
        });
      }
      // The exporter samples the timeline at the document's fps. Below the footage's own rate it
      // cannot help but drop frames, and the result reads as stutter rather than as motion.
      if (document.kind === "animated" && document.fps < layer.frameRate) {
        context.addIssue({
          code: "custom",
          message: `Sequence layer ${layer.id} plays at ${layer.frameRate} fps but the document `
            + `renders at ${document.fps}, so frames would be dropped. Raise the document's fps.`,
        });
      }
    }

    // A layer with declarative specs must carry exactly their compiled output. Storing both
    // representations is only safe if they can never disagree, and this is what enforces that.
    if (layer.animations.length > 0) {
      try {
        const expected = compileLayerAnimation(layer.animations, layer.anchor, timing);
        if (canonicalJson(expected) !== canonicalJson(layer.animation)) {
          context.addIssue({
            code: "custom",
            message: `Layer ${layer.id} has compiled keyframes that do not match its animations. `
              + "Rebuild it with the setLayerAnimations operation instead of editing keyframes directly.",
          });
        }
      } catch (error) {
        context.addIssue({
          code: "custom",
          message: `Layer ${layer.id}: ${error instanceof Error ? error.message : String(error)}`,
        });
      }
    }

    // Widened to the one field every channel shares. Enumerating the channels instead of spreading
    // them by hand is what keeps a newly added channel from silently escaping these two checks.
    const timedKeyframes: ReadonlyArray<{ timeSeconds: number }> = ANIMATION_CHANNELS
      .flatMap((channel) => layer.animation[channel] as ReadonlyArray<{ timeSeconds: number }>);
    for (const keyframe of timedKeyframes) {
      if (keyframe.timeSeconds > document.durationSeconds) {
        context.addIssue({
          code: "custom",
          message: `Layer ${layer.id} has a keyframe beyond durationSeconds`,
        });
      }
      if (document.kind === "static" && keyframe.timeSeconds !== 0) {
        context.addIssue({
          code: "custom",
          message: `Static layer ${layer.id} may only use timeSeconds 0`,
        });
      }
    }
  }

  if (totalKeyframes > 128) {
    context.addIssue({ code: "custom", message: "StickerDocument allows at most 128 keyframes" });
  }

  // Inline SVG makes a document's byte size unbounded in a way v1's never was: twelve layers at the
  // 200 KB per-layer markup cap is 2.4 MB, which no route could accept. The whole body is also
  // hashed into an idempotency key and stored in its response row, so this bounds three things at
  // once. Checked last because it is the only rule that needs the document serialized.
  const byteSize = Buffer.byteLength(JSON.stringify(document), "utf8");
  if (byteSize > MAX_DOCUMENT_BYTES) {
    context.addIssue({
      code: "custom",
      message: `StickerDocument is ${byteSize} bytes, over the ${MAX_DOCUMENT_BYTES}-byte limit. `
        + "Shorten or link out an inline SVG layer.",
    });
  }
});

export const StickerOperationV1Schema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("addLayer"), layer: StickerLayerV1Schema, index: z.number().int().min(0).max(7).optional() }).strict(),
  z.object({ op: z.literal("removeLayer"), layerId: LayerIdSchema }).strict(),
  z.object({ op: z.literal("reorderLayer"), layerId: LayerIdSchema, index: z.number().int().min(0).max(7) }).strict(),
  z.object({ op: z.literal("renameLayer"), layerId: LayerIdSchema, name: z.string().trim().min(1).max(80) }).strict(),
  z.object({ op: z.literal("replaceAsset"), layerId: LayerIdSchema, assetId: AssetIdSchema, maskAssetId: AssetIdSchema.optional() }).strict(),
  /**
   * Sets a layer's declarative motion and recompiles its keyframes.
   *
   * This is the operation the planner should reach for: it expresses motion as named effects with
   * delays instead of absolute timestamps, and it cannot leave the two representations out of sync.
   */
  z.object({
    op: z.literal("setLayerAnimations"),
    layerId: LayerIdSchema,
    animations: z.array(AnimationSpecV1Schema).max(12),
    anchor: LayerAnchorV1Schema.optional(),
  }).strict(),
  z.object({ op: z.literal("setPositionKeyframes"), layerId: LayerIdSchema, keyframes: z.array(PositionKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setScaleKeyframes"), layerId: LayerIdSchema, keyframes: z.array(ScaleKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setRotationKeyframes"), layerId: LayerIdSchema, keyframes: z.array(RotationKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setOpacityKeyframes"), layerId: LayerIdSchema, keyframes: z.array(OpacityKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setEffectKeyframes"), layerId: LayerIdSchema, keyframes: z.array(EffectKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setTrimKeyframes"), layerId: LayerIdSchema, keyframes: z.array(TrimKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setWipeKeyframes"), layerId: LayerIdSchema, keyframes: z.array(WipeKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setSheenKeyframes"), layerId: LayerIdSchema, keyframes: z.array(SheenKeyframeV1Schema).max(32) }).strict(),
  z.object({ op: z.literal("setGlowKeyframes"), layerId: LayerIdSchema, keyframes: z.array(GlowKeyframeV1Schema).max(32) }).strict(),
  z.object({
    op: z.literal("setTiming"),
    durationSeconds: z.number().min(0.5).max(4),
    fps: z.number().int().min(1).max(30),
    loop: z.enum(["once", "loop", "pingPong"]),
  }).strict(),
  z.object({ op: z.literal("setMp4Background"), background: Mp4BackgroundV1Schema }).strict(),
  /**
   * Retimes captured footage without rebuilding the layer.
   *
   * This is the only sequence-specific operation, deliberately. Everything else the agent might
   * want to do to captured frames — move, scale, rotate, animate, reorder, rename, hide — already
   * works, because a sequence layer carries an ordinary `LayerBase`. There is no operation to
   * *replace* the footage: re-lifting a subject is something the user does in the picker, not
   * something the model can do on their behalf.
   */
  z.object({
    op: z.literal("setSequencePlayback"),
    layerId: LayerIdSchema,
    playback: z.enum(["loop", "once", "pingPong"]),
    startSeconds: z.number().min(0).max(30).default(0),
  }).strict(),
]);

export const StickerOperationsV1Schema = z.array(StickerOperationV1Schema).min(1).max(32);

export type StickerDocument = z.infer<typeof StickerDocumentSchema>;
export type StickerLayerV1 = z.infer<typeof StickerLayerV1Schema>;
export type LayerAnchorV1 = z.infer<typeof LayerAnchorV1Schema>;
export type StickerOperationV1 = z.infer<typeof StickerOperationV1Schema>;
/**
 * An operation as a caller writes it, with defaulted fields still optional.
 *
 * `applyStickerOperationsV1` parses its input, so requiring the fully-defaulted output type would
 * force every caller to spell out `anchor`, `animations`, `easing`, and friends by hand.
 */
export type StickerOperationV1Input = z.input<typeof StickerOperationV1Schema>;

/**
 * The bitmap assets a layer needs before it can be drawn.
 *
 * Exists because five separate places used to spell out `layer.type === "image"` inline — the
 * renderer, the ownership check, the reuse list, the export pre-flight, and the client's preloader.
 * All five kept compiling when `sequence` was added and would have quietly rendered placeholders.
 * A single exhaustive switch turns that into a build error at one site.
 *
 * `posterAssetId` is not here: nothing draws it, and the callers that *do* need to vouch for it —
 * ownership and reference validation — ask for it explicitly. `svg` asset sources are not here
 * either; they resolve to markup, not to pixels, and their one consumer collects them separately.
 * Mirrors `AnimatedLayer.referencedImageAssetIDs` in Swift.
 */
export function layerImageAssetIds(layer: StickerLayerV1): string[] {
  switch (layer.type) {
  case "image":
    return layer.maskAssetId ? [layer.assetId, layer.maskAssetId] : [layer.assetId];
  case "sequence":
    return [layer.assetId];
  case "text":
  case "shape":
  case "svg":
  case "particle":
    return [];
  }
}

function timingOf(document: StickerDocument): AnimationTiming {
  return { kind: document.kind, durationSeconds: document.durationSeconds };
}

/** Rejects hand-editing a channel on a layer whose motion is owned by declarative specs. */
function assertNotDeclarative(layer: StickerLayerV1, operation: string): void {
  if (layer.animations.length > 0) {
    throw new Error(
      `Layer ${layer.id} is animated declaratively, so ${operation} would be overwritten. `
      + "Use setLayerAnimations to change its motion.",
    );
  }
}

export function applyStickerOperationsV1(
  source: StickerDocument,
  operations: readonly StickerOperationV1Input[],
): StickerDocument {
  const document = structuredClone(source) as StickerDocument;

  for (const operation of StickerOperationsV1Schema.parse(operations)) {
    if (operation.op === "addLayer") {
      const index = operation.index ?? document.layers.length;
      document.layers.splice(index, 0, operation.layer);
      continue;
    }

    if (operation.op === "setTiming") {
      if (document.kind !== "animated") throw new Error("Cannot set timing on a static sticker");
      document.durationSeconds = operation.durationSeconds;
      document.fps = operation.fps;
      document.loop = operation.loop;
      // Every compiled keyframe is an absolute time derived from the old duration, so the tracks
      // are stale the moment the duration changes. Specs are relative, so recompiling fixes them.
      for (const layer of document.layers) {
        if (layer.animations.length === 0) continue;
        layer.animation = compileLayerAnimation(layer.animations, layer.anchor, timingOf(document));
      }
      continue;
    }

    if (operation.op === "setMp4Background") {
      document.mp4Background = operation.background;
      continue;
    }

    const index = document.layers.findIndex((layer) => layer.id === operation.layerId);
    if (index < 0) throw new Error(`Unknown layer: ${operation.layerId}`);

    if (operation.op === "removeLayer") {
      document.layers.splice(index, 1);
    } else if (operation.op === "reorderLayer") {
      const [layer] = document.layers.splice(index, 1);
      document.layers.splice(operation.index, 0, layer);
    } else if (operation.op === "renameLayer") {
      document.layers[index].name = operation.name;
    } else if (operation.op === "replaceAsset") {
      const layer = document.layers[index];
      if (layer.type !== "image") throw new Error(`Layer ${operation.layerId} is not an image layer`);
      layer.assetId = operation.assetId;
      layer.maskAssetId = operation.maskAssetId;
    } else if (operation.op === "setSequencePlayback") {
      const layer = document.layers[index];
      if (layer.type !== "sequence") throw new Error(`Layer ${operation.layerId} is not a sequence layer`);
      layer.playback = operation.playback;
      layer.startSeconds = operation.startSeconds;
    } else if (operation.op === "setLayerAnimations") {
      const layer = document.layers[index];
      if (operation.anchor) layer.anchor = operation.anchor;
      layer.animations = operation.animations;
      layer.animation = compileLayerAnimation(layer.animations, layer.anchor, timingOf(document));
    } else if (operation.op === "setPositionKeyframes") {
      assertNotDeclarative(document.layers[index], "setPositionKeyframes");
      document.layers[index].animation.position = operation.keyframes;
    } else if (operation.op === "setScaleKeyframes") {
      assertNotDeclarative(document.layers[index], "setScaleKeyframes");
      document.layers[index].animation.scale = operation.keyframes;
    } else if (operation.op === "setRotationKeyframes") {
      assertNotDeclarative(document.layers[index], "setRotationKeyframes");
      document.layers[index].animation.rotation = operation.keyframes;
    } else if (operation.op === "setOpacityKeyframes") {
      assertNotDeclarative(document.layers[index], "setOpacityKeyframes");
      document.layers[index].animation.opacity = operation.keyframes;
    } else if (operation.op === "setEffectKeyframes") {
      assertNotDeclarative(document.layers[index], "setEffectKeyframes");
      document.layers[index].animation.effects = operation.keyframes;
    } else if (operation.op === "setTrimKeyframes") {
      assertNotDeclarative(document.layers[index], "setTrimKeyframes");
      document.layers[index].animation.trim = operation.keyframes;
    } else if (operation.op === "setWipeKeyframes") {
      assertNotDeclarative(document.layers[index], "setWipeKeyframes");
      document.layers[index].animation.wipe = operation.keyframes;
    } else if (operation.op === "setSheenKeyframes") {
      assertNotDeclarative(document.layers[index], "setSheenKeyframes");
      document.layers[index].animation.sheen = operation.keyframes;
    } else if (operation.op === "setGlowKeyframes") {
      assertNotDeclarative(document.layers[index], "setGlowKeyframes");
      document.layers[index].animation.glow = operation.keyframes;
    }
  }

  return StickerDocumentSchema.parse(document);
}
