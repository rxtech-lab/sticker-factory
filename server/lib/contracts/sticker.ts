import { z } from "zod";
import { compileLayerAnimation, type AnimationTiming } from "@/lib/animation/compile";
import {
  AnimationSpecV1Schema,
  DEFAULT_ANCHOR,
  EffectKeyframeV1Schema,
  LayerAnimationV1Schema,
  OpacityKeyframeV1Schema,
  PositionKeyframeV1Schema,
  RotationKeyframeV1Schema,
  ScaleKeyframeV1Schema,
  StickerEasingV1Schema,
} from "@/lib/contracts/animation";

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

const AssetIdSchema = z.string().uuid();
export const LayerIdSchema = z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/);
const HexColorSchema = z.string().regex(/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/);

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
  /** Compiled keyframes. This is the only thing the renderer and exporter read. */
  animation: LayerAnimationV1Schema.default({
    position: [],
    scale: [],
    rotation: [],
    opacity: [],
    effects: [],
  }),
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
  color: HexColorSchema,
  alignment: z.enum(["leading", "center", "trailing"]).default("center"),
}).strict();

export const ShapeLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("shape"),
  shape: z.enum(["circle", "roundedRectangle", "star", "heart", "burst"]),
  fill: HexColorSchema,
  stroke: HexColorSchema.optional(),
  strokeWidth: z.number().min(0).max(0.08).default(0),
  cornerRadius: z.number().min(0).max(0.5).default(0.12),
}).strict();

export const ParticleLayerV1Schema = LayerBaseSchema.extend({
  type: z.literal("particle"),
  preset: z.enum(["sparkles", "confetti", "hearts", "bubbles", "snow"]),
  count: z.number().int().min(1).max(64),
  color: HexColorSchema,
  seed: z.number().int().min(0).max(2_147_483_647),
}).strict();

export const StickerLayerV1Schema = z.discriminatedUnion("type", [
  ImageLayerV1Schema,
  TextLayerV1Schema,
  ShapeLayerV1Schema,
  ParticleLayerV1Schema,
]);

export const Mp4BackgroundV1Schema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("solid"), color: HexColorSchema }).strict(),
  z.object({
    type: z.literal("linearGradient"),
    colors: z.tuple([HexColorSchema, HexColorSchema]),
    angleDegrees: z.number().min(0).max(360),
  }).strict(),
]);

const DocumentBaseSchema = z.object({
  version: z.literal(1),
  canvas: z.object({
    width: z.literal(1024),
    height: z.literal(1024),
    coordinateSpace: z.literal("normalized"),
    transparent: z.literal(true),
  }).strict(),
  layers: z.array(StickerLayerV1Schema).max(8),
  mp4Background: Mp4BackgroundV1Schema.default({ type: "solid", color: "#FFFFFF" }),
}).strict();

const StaticDocumentV1Schema = DocumentBaseSchema.extend({
  kind: z.literal("static"),
  durationSeconds: z.literal(0),
  fps: z.literal(0),
  loop: z.literal("once"),
}).strict();

const AnimatedDocumentV1Schema = DocumentBaseSchema.extend({
  kind: z.literal("animated"),
  durationSeconds: z.number().min(0.5).max(4).default(2),
  fps: z.number().int().min(1).max(30).default(30),
  loop: z.enum(["once", "loop", "pingPong"]).default("loop"),
}).strict();

function keyframeCount(layer: z.infer<typeof StickerLayerV1Schema>): number {
  const animation = layer.animation;
  return animation.position.length + animation.scale.length + animation.rotation.length
    + animation.opacity.length + animation.effects.length;
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

export const StickerDocumentV1Schema = z.discriminatedUnion("kind", [
  StaticDocumentV1Schema,
  AnimatedDocumentV1Schema,
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

    for (const keyframe of [
      ...layer.animation.position,
      ...layer.animation.scale,
      ...layer.animation.rotation,
      ...layer.animation.opacity,
      ...layer.animation.effects,
    ]) {
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
    context.addIssue({ code: "custom", message: "StickerDocumentV1 allows at most 128 keyframes" });
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
  z.object({
    op: z.literal("setTiming"),
    durationSeconds: z.number().min(0.5).max(4),
    fps: z.number().int().min(1).max(30),
    loop: z.enum(["once", "loop", "pingPong"]),
  }).strict(),
  z.object({ op: z.literal("setMp4Background"), background: Mp4BackgroundV1Schema }).strict(),
]);

export const StickerOperationsV1Schema = z.array(StickerOperationV1Schema).min(1).max(32);

export type StickerDocumentV1 = z.infer<typeof StickerDocumentV1Schema>;
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

function timingOf(document: StickerDocumentV1): AnimationTiming {
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
  source: StickerDocumentV1,
  operations: readonly StickerOperationV1Input[],
): StickerDocumentV1 {
  const document = structuredClone(source) as StickerDocumentV1;

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
    }
  }

  return StickerDocumentV1Schema.parse(document);
}
