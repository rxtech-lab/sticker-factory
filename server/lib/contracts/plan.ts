import { z } from "zod";
import { PosePresetSchema, POSE_COUNTS, type PosePreset } from "./pose-preset";
import { PlanConfigurationSchema, PlanConfigurationChangesSchema, configurationIssues, configurationKeepingLayers } from "./configuration";
import {
  compileLayerAnimations,
  type AnimationTiming,
  type LayerCompileInput,
} from "@/lib/animation/compile";
import {
  AnimationSpecV1Schema,
  MAX_TIME_SECONDS,
  type AnimationAnchorV1,
  type AnimationSpecV1,
} from "@/lib/contracts/animation";
import {
  aspectLockedScale,
  layerScaleIsAspectLocked,
  LayerIdSchema,
  documentRenderableLayers,
  type StickerDocument,
  type StickerLayerV1,
} from "@/lib/contracts/sticker";

const HexColorSchema = z.string().regex(/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/);

/**
 * Where a planned layer's content comes from.
 *
 * Only `generate` costs an image generation. Text, shape, and particle layers are assembled
 * directly from the plan, and `existing` reuses artwork the sticker already has, which is why a plan
 * can be far cheaper than its layer count suggests.
 */
export const PlanLayerSourceV1Schema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("generate"),
    /** Describes one element filling its frame on a transparent background. */
    prompt: z.string().trim().min(1).max(2_000),
  }).strict(),
  z.object({
    kind: z.literal("existing"),
    /**
     * Artwork the sticker already has, reused pixel for pixel and free.
     *
     * This is what makes revising a planned sticker cheap: a plan that moves one layer and drops
     * another keeps every other layer's `assetId` instead of paying to redraw art the user already
     * approved — which would also come back looking different.
     *
     * The id is copied from an image layer of the current document. Nothing in this schema can tell
     * whether it names one, so the planning turn checks it against that document before the plan is
     * stored; a hallucinated id has to reach the model as a repairable tool error, not as a build
     * that fails after the user has confirmed it.
     */
    assetId: z.string().uuid(),
  }).strict(),
  z.object({
    kind: z.literal("text"),
    text: z.string().min(1).max(160),
    font: z.enum(["rounded", "serif", "monospaced", "system"]).default("rounded"),
    weight: z.enum(["regular", "medium", "semibold", "bold"]).default("bold"),
    color: HexColorSchema,
    alignment: z.enum(["leading", "center", "trailing"]).default("center"),
  }).strict(),
  z.object({
    kind: z.literal("shape"),
    shape: z.enum(["circle", "roundedRectangle", "star", "heart", "burst"]),
    fill: HexColorSchema,
    stroke: HexColorSchema.optional(),
    strokeWidth: z.number().min(0).max(0.08).default(0),
    cornerRadius: z.number().min(0).max(0.5).default(0.12),
  }).strict(),
  z.object({
    kind: z.literal("particle"),
    preset: z.enum(["sparkles", "confetti", "hearts", "bubbles", "snow"]),
    count: z.number().int().min(1).max(64).default(24),
    color: HexColorSchema,
    seed: z.number().int().min(0).max(2_147_483_647).default(1),
  }).strict(),
  z.object({
    /**
     * Real frames the user captured, already cut out on device. Free, like `existing`, and the only
     * source that carries genuine motion — the subject actually moves the way they moved.
     *
     * The planner never invents one of these: the ids and the grid come from an attachment on the
     * message, and the planning turn hands them to the model. Nothing here can tell whether the
     * asset exists, so `assertPlanReuseIsResolvable` checks it against the sticker before the plan
     * is stored, the same way it does for `existing`.
     */
    kind: z.literal("sequence"),
    assetId: z.string().uuid(),
    columns: z.number().int().min(1).max(8),
    rows: z.number().int().min(1).max(8),
    frameCount: z.number().int().min(1).max(64),
    frameRate: z.number().min(1).max(60),
    playback: z.enum(["loop", "once", "pingPong"]).default("pingPong"),
  }).strict(),
  z.object({
    /**
     * A short generated clip of the whole subject, for motion keyframes cannot express: a 3D
     * turnaround, a change of viewing angle, a camera move, cloth, hair, or liquid physics, a
     * morph between forms.
     *
     * Costs one image generation (the still it is animated from, separated from the approved
     * reference like any `generate` layer) plus one video generation. The clip is shot against a
     * chroma backdrop and keyed out on the device, so it composites like every other layer.
     */
    kind: z.literal("video"),
    /** What to draw: the complete subject, same rules as a generate prompt. */
    prompt: z.string().trim().min(1).max(2_000),
    /** What the subject or camera does, e.g. "slow 360° turntable rotation, one full turn". */
    motion: z.string().trim().min(1).max(500),
    /** The video model's floor is 2 s; the plan timing's ceiling is 4 s. */
    durationSeconds: z.number().int().min(2).max(4).default(3),
  }).strict(),
  z.object({
    /**
     * A controllable character: one still, a few named body clips, and a strip of face expressions.
     *
     * Costs `1 + clips + 1` image generations: the still is separated from the approved reference
     * like a `generate` layer, every clip is one sprite sheet, and all the expressions share one
     * sheet. Mood and pose controls then bind `expression` and `clip` on the built layer, so the
     * combinations are free — see `SpriteLayerV1Schema`.
     */
    kind: z.literal("sprite"),
    /** What to draw: the complete character at rest, same rules as a generate prompt. */
    prompt: z.string().trim().min(1).max(2_000),
    /**
     * Where the character's single face region is and what sits inside it, e.g. "the windshield:
     * both eyes and the mouth are inside the glass; grille and bumper carry no facial features".
     *
     * The build cuts exactly one oval out of the body there and draws every expression inside it,
     * so every eye, brow, nose and mouth has to live in this one contiguous area and nothing facial
     * may be drawn anywhere else. Optional in the schema so plans stored before it existed still
     * parse; `assertSpriteFaces` requires it of every newly drafted plan.
     */
    face: z.string().trim().min(1).max(300).optional(),
    clips: z.array(z.object({
      id: LayerIdSchema,
      label: z.string().trim().min(1).max(80),
      /** Use masked when a hand, cup, instrument, or other body artwork passes in front of the face. */
      faceCompositing: z.enum(["overlay", "masked"]).default("overlay"),
      /** What the body does across the frames, in order. The first frame is the resting pose. */
      prompt: z.string().trim().min(1).max(1_000),
      /** How long each frame holds. Six frames is the norm; a still pose may be one. */
      frames: z.array(z.object({ duration: z.number().min(0.05).max(10) }).strict()).min(1).max(8),
    }).strict()).min(1).max(8),
    expressions: z.array(z.object({
      id: LayerIdSchema,
      label: z.string().trim().min(1).max(80),
      /** The face alone: eyes, brows, mouth, cheeks. The first entry is the neutral face. */
      prompt: z.string().trim().min(1).max(500),
    }).strict()).min(1).max(8),
  }).strict(),
]);

/** The default sheet grid for a clip of `count` frames: 3x2 up to six, 4x2 up to eight. */
export function spriteSheetGrid(count: number): { columns: number; rows: number } {
  return count <= 6 ? { columns: 3, rows: 2 } : { columns: 4, rows: 2 };
}

/** Sprite layers of a plan, with their sources narrowed. */
export function planSpriteLayers(plan: Pick<PlanV1, "layers">) {
  return plan.layers.flatMap((layer) => (
    layer.source.kind === "sprite" ? [{ layer, source: layer.source }] : []
  ));
}

/**
 * One layer of a planned sticker.
 *
 * Ranges are deliberately narrower than the underlying keyframe schema (position allows -1..2,
 * scale allows 0.05..8) so the planner cannot place a layer off-canvas or blow it up past the
 * frame. `x`/`y` are the normalized centre of the layer on the 1024x1024 canvas.
 */
export const PlanLayerV1Schema = z.object({
  layerId: LayerIdSchema,
  name: z.string().trim().min(1).max(80),
  source: PlanLayerSourceV1Schema,
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  scaleX: z.number().min(0.05).max(1),
  scaleY: z.number().min(0.05).max(1),
  rotationDegrees: z.number().min(-180).max(180).default(0),
  /** Named motion effects with delays, compiled to keyframes when the plan is executed. */
  animations: z.array(AnimationSpecV1Schema).max(12).default([]),
}).strict().superRefine((layer, context) => {
  // Checked on the layer rather than on the source, because `PlanLayerSourceV1Schema` is a
  // discriminated union and a member carrying a refinement is wrapped in an effect zod cannot see
  // the literal `kind` through — the same reason `StickerLayerV1Schema` stopped being one.
  //
  // Worth catching here at all because the document schema enforces the identical rule: without
  // this, an impossible grid survives planning and fails when the *confirmed* plan is built, long
  // after the user approved it and with an error they cannot act on.
  if (layer.source.kind === "sequence" && layer.source.frameCount > layer.source.rows * layer.source.columns) {
    context.addIssue({
      code: "custom",
      path: ["source", "frameCount"],
      message: `Layer ${layer.layerId} declares ${layer.source.frameCount} captured frames but its `
        + `${layer.source.rows}x${layer.source.columns} grid holds only ${layer.source.rows * layer.source.columns}. `
        + "Copy columns, rows, frameCount, and frameRate exactly as they were given to you.",
    });
  }
  if (layer.source.kind === "sprite") {
    const clipIds = layer.source.clips.map((clip) => clip.id);
    if (new Set(clipIds).size !== clipIds.length) {
      context.addIssue({ code: "custom", path: ["source", "clips"], message: `Layer ${layer.layerId} repeats a clip id; give every clip its own id` });
    }
    const expressionIds = layer.source.expressions.map((expression) => expression.id);
    if (new Set(expressionIds).size !== expressionIds.length) {
      context.addIssue({ code: "custom", path: ["source", "expressions"], message: `Layer ${layer.layerId} repeats an expression id; give every expression its own id` });
    }
  }
});

/** Layers one plan may hold. Twelve rather than eight: a two-character scene spends two of them
 *  before any scenery. Served to the plan editor with the rest of the budget. */
export const MAX_PLAN_LAYERS = 12;

export const PlanTimingV1Schema = z.object({
  durationSeconds: z.number().min(0.5).max(4).default(2),
  fps: z.number().int().min(1).max(30).default(30),
  loop: z.enum(["once", "loop", "pingPong"]).default("loop"),
}).strict();

/**
 * The whole design of a sticker, which the agent drafts and revises before anything is generated.
 *
 * A plan is a mutable draft: the agent creates one, updates it as many times as it needs, shows it,
 * and finalizes it. Only a finalized plan can be confirmed by the user, and only a confirmed plan
 * generates images.
 */
export const PlanV1Schema = z.object({
  engine: z.enum(["legacy", "svg"]).optional(),
  baseRevisionId: z.string().uuid().optional(),
  configurationChanges: PlanConfigurationChangesSchema.optional(),
  posePreset: PosePresetSchema.optional(),
  configuration: PlanConfigurationSchema.optional(),
  version: z.literal(1).default(1),
  title: z.string().trim().min(1).max(120),
  /** Shown to the user as the assistant's chat message: one or two friendly sentences. */
  summary: z.string().trim().min(1).max(1_000),
  kind: z.enum(["static", "animated"]),
  timing: PlanTimingV1Schema.default({ durationSeconds: 2, fps: 30, loop: "loop" }),
  layers: z.array(PlanLayerV1Schema).max(MAX_PLAN_LAYERS),
  /**
   * How to draw the finished static reference the user approves before animated parts are made.
   *
   * Older plans may not carry this field, so it remains optional in the persisted v1 schema. The
   * workflow derives a complete fallback prompt for animated plans, which means every new animated
   * plan still has a reference image before it becomes actionable.
   */
  conceptPrompt: z.string().trim().min(1).max(2_000).optional(),
}).strict().superRefine((plan, context) => {
  if (!plan.baseRevisionId && !plan.layers.length) context.addIssue({ code: "custom", message: "A new plan needs layers" });
  if (plan.configurationChanges && !plan.baseRevisionId) context.addIssue({ code: "custom", message: "Configuration changes need a base revision" });
  if (plan.baseRevisionId && plan.configuration) context.addIssue({ code: "custom", message: "Extension plans use configurationChanges; omitted controls are preserved" });
  if (plan.baseRevisionId && !plan.layers.length && !plan.configurationChanges) context.addIssue({ code: "custom", message: "An extension needs layer or control changes" });
  if (plan.posePreset && !plan.baseRevisionId) {
    try { assertPlanPosePreset(plan, plan.posePreset); }
    catch (error) { context.addIssue({ code: "custom", path: ["posePreset"], message: (error as Error).message }); }
  }
  if (plan.configuration) {
    const issues = configurationIssues(plan.configuration, new Set(plan.layers.map((layer) => layer.layerId)));
    if (plan.kind !== "animated") issues.push("Configurable stickers need an animated plan");
    for (const variant of plan.configuration.variants) {
      for (const patch of variant.layers) {
        const layer = plan.layers.find((layer) => layer.layerId === patch.layerId);
        if ((patch.source?.kind === "frames" || patch.source?.kind === "sequence") && patch.source.frameRate > plan.timing.fps) issues.push("Pose frame rate exceeds plan frame rate");
        // A clip or expression binding only means something on a sprite, and only for an id the
        // sprite declares; a sprite's artwork is never swapped whole, its parts are selected.
        if (patch.clip !== undefined || patch.expression !== undefined) {
          if (layer?.source.kind !== "sprite") {
            issues.push(`Variant ${variant.id} selects a clip or expression on ${patch.layerId}, which is not a sprite layer`);
          } else {
            if (patch.clip !== undefined && !layer.source.clips.some((clip) => clip.id === patch.clip)) {
              issues.push(`Variant ${variant.id} selects clip ${patch.clip}, which sprite ${patch.layerId} does not declare`);
            }
            if (patch.expression !== undefined && !layer.source.expressions.some((expression) => expression.id === patch.expression)) {
              issues.push(`Variant ${variant.id} selects expression ${patch.expression}, which sprite ${patch.layerId} does not declare`);
            }
          }
        }
        if (patch.source && layer?.source.kind === "sprite") {
          issues.push(`Variant ${variant.id} replaces the artwork of sprite ${patch.layerId}; bind clip or expression on a sprite instead`);
        }
        if (patch.animations && layer) {
          try { compilePlanAnimations({ ...plan, layers: [{ ...layer, animations: patch.animations }] }); }
          catch (error) { issues.push(error instanceof Error ? error.message : String(error)); }
        }
      }
    }
    for (const message of issues) context.addIssue({ code: "custom", message });
  }
  const ids = new Set<string>();
  for (const layer of plan.layers) {
    if (ids.has(layer.layerId)) {
      context.addIssue({ code: "custom", message: `Duplicate plan layer id: ${layer.layerId}` });
    }
    ids.add(layer.layerId);
  }

  // Video rules live here rather than on the source for the same reason the sequence grid check
  // lives on the layer: a refinement on a union member hides its `kind` from the discriminator.
  const videos = plan.layers.filter((layer) => layer.source.kind === "video");
  if (videos.length > 0 && plan.kind === "static") {
    context.addIssue({
      code: "custom",
      message: `Layer ${videos[0].layerId} is a video source, which needs an animated plan. `
        + "Make the plan animated, or draw the layer with a generate source.",
    });
  }
  if (videos.length > 1) {
    context.addIssue({
      code: "custom",
      message: `At most one video layer per plan; ${videos.map((layer) => layer.layerId).join(", ")} are all video. `
        + "Keep the one whose motion genuinely needs a clip and draw the rest with generate sources.",
    });
  }
  // The summary is the assistant's chat message. A clip costs more and looks different from drawn
  // artwork, so the user is told which layer is one before they confirm — not after it was billed.
  if (videos.length > 0 && !/\bvideo\b/i.test(plan.summary)) {
    context.addIssue({
      code: "custom",
      path: ["summary"],
      message: "Say in the summary which layer is generated as a video and why its motion needs one.",
    });
  }
  // A sprite only makes sense with a timeline to walk its clips on. It is also the one source whose
  // cost the user cannot read off the layer count, so the plan says what it buys.
  const sprites = planSpriteLayers(plan);
  if (sprites.length > 0 && plan.kind === "static") {
    context.addIssue({
      code: "custom",
      message: `${sprites.map(({ layer }) => `Layer ${layer.layerId}`).join(", ")} `
        + `${sprites.length > 1 ? "are sprite characters, which need" : "is a sprite character, which needs"} an animated plan.`,
    });
  }

  // Compile here so a plan that cannot become a document can never be stored, let alone finalized.
  // Failing at draft time costs nothing; failing during execution would waste paid image generations.
  try {
    compilePlanAnimations(plan);
  } catch (error) {
    context.addIssue({
      code: "custom",
      message: error instanceof Error ? error.message : String(error),
    });
  }
});

export type PlanLayerSourceV1 = z.infer<typeof PlanLayerSourceV1Schema>;
export type PlanLayerV1 = z.infer<typeof PlanLayerV1Schema>;
export type PlanV1 = z.infer<typeof PlanV1Schema>;

/** Only authored definitions: extension builds must never regenerate the base configuration. */
export function plannedConfiguration(plan: Pick<PlanV1, "configuration" | "configurationChanges">) {
  return plan.configuration ?? (plan.configurationChanges ? {
    controls: plan.configurationChanges.upsertControls ?? [],
    variants: plan.configurationChanges.upsertVariants ?? [],
  } : undefined);
}

export const PlanStates = ["draft", "finalized", "confirmed", "superseded", "cancelled"] as const;
export type PlanState = (typeof PlanStates)[number];

/** States in which the agent may still edit the plan. */
export const isEditablePlanState = (state: PlanState) => state === "draft";
/** States in which the user may confirm or cancel the plan. */
export const isActionablePlanState = (state: PlanState) => state === "finalized";

/** The document timing a plan implies. Static plans pin everything to zero. */
export function planTiming(plan: Pick<PlanV1, "kind" | "timing">): AnimationTiming {
  return plan.kind === "static"
    ? { kind: "static", durationSeconds: 0 }
    : { kind: "animated", durationSeconds: plan.timing.durationSeconds };
}

/**
 * The layer type a plan source becomes once the plan is built.
 *
 * Only used to ask whether the layer will hold pixels, so `generate` and `existing` collapse onto
 * the same answer they will have in the document: both are ordinary image layers by then.
 */
function plannedLayerType(source: PlanLayerSourceV1): StickerLayerV1["type"] {
  switch (source.kind) {
  case "generate":
  case "existing":
    return "image";
  case "sequence":
    return "sequence";
  case "video":
    return "video";
  case "sprite":
    return "sprite";
  case "text":
    return "text";
  case "shape":
    return "shape";
  case "particle":
    return "particle";
  }
}

/**
 * The resting state a planned layer's motion departs from and returns to.
 *
 * A pixel-backed layer's scale is squared off here rather than trusted as authored. Planners write
 * `scaleX`/`scaleY` as the box they want an element to occupy, and for a wide caption they write a
 * wide box — but the artwork behind it is a square PNG drawn to fill its frame, so the renderer's
 * `scale(x, y)` stretched it to match. Fitting it inside the planned box instead is the only
 * reading that keeps the picture the user approved undistorted.
 */
export function planLayerAnchor(layer: PlanLayerV1): AnimationAnchorV1 {
  const scale = { x: layer.scaleX, y: layer.scaleY };
  return {
    position: { x: layer.x, y: layer.y },
    scale: layerScaleIsAspectLocked(plannedLayerType(layer.source)) ? aspectLockedScale(scale) : scale,
    rotationDegrees: layer.rotationDegrees,
    opacity: 1,
    // A plan never trims: draw-on is authored as a spec, not as a resting window, so a planned
    // layer always starts out showing its whole path.
    trim: { start: 0, end: 1 },
  };
}

/**
 * Compiles every planned layer's motion, in plan-layer order.
 *
 * Shared by the plan refinement and by document assembly so the keyframes a user approved are
 * exactly the keyframes that get built.
 */
export function compilePlanAnimations(plan: Pick<PlanV1, "kind" | "timing" | "layers">) {
  const inputs: LayerCompileInput[] = plan.layers.map((layer) => ({
    layerId: layer.layerId,
    specs: layer.animations,
    anchor: planLayerAnchor(layer),
  }));
  return compileLayerAnimations(inputs, planTiming(plan));
}

/**
 * How many image generations executing this plan will cost.
 *
 * A video layer counts: its clip is animated from a still that is separated from the approved
 * reference exactly the way a generate layer's artwork is, so it pays for that image first.
 */
export function planGenerationCount(plan: Pick<PlanV1, "layers" | "configuration" | "configurationChanges" | "baseRevisionId" | "engine">): number {
  const alternatives = plannedConfiguration(plan)?.variants.flatMap((variant) => variant.layers).filter((layer) => layer.source?.kind === "generate" || layer.source?.kind === "frames").length ?? 0;
  const stills = plan.layers.filter((layer) => layer.source.kind === "generate" || layer.source.kind === "video" || layer.source.kind === "sprite").length;
  return alternatives + stills + planSpriteSheetCount(plan);
}

/**
 * How many sprite sheets executing this plan will draw: one per clip plus one expression sheet per
 * sprite layer. Counted apart from the stills because a sheet is drawn at a higher quality and
 * holds more than an ordinary generation.
 */
export function planSpriteSheetCount(plan: Pick<PlanV1, "layers" | "engine">): number {
  return plan.engine === "svg" ? 0 : planSpriteLayers(plan).reduce((total, { source }) => total + source.clips.length + 1, 0);
}

/** How many video generations executing this plan will cost, on top of its image generations. */
export function planVideoCount(plan: Pick<PlanV1, "layers">): number {
  return plan.layers.filter((layer) => layer.source.kind === "video").length;
}

/**
 * Motion that carries a character around the canvas rather than letting it act in place.
 *
 * Entrances and exits are deliberately absent. `slideIn` and `slideOut` travel too, but they are
 * one-shot arrivals and departures rather than a restless idle, and a sticker that is asked to hold
 * still may still arrive. What makes a resting character look wrong is the repeating drift —
 * `float` and `bounce` — and the absolute moves that relocate it, `moveTo` and `arcTo`.
 */
const TRAVELLING_SPEC_TYPES: ReadonlySet<string> = new Set(["float", "bounce", "moveTo", "arcTo"]);

/**
 * Strips travel from a plan whose sticker was asked to stay put.
 *
 * Done deterministically rather than left to the prompt because "the plane bobs when I did not ask
 * it to" is exactly the kind of instruction a model drops one plan in ten, and the cost of it
 * slipping through is a sheet the user pays to redraw. The prompt still asks — this is the floor,
 * not the whole mechanism.
 *
 * Only layer-level animation is removed. A sprite's clips are frames the artwork is drawn into, so
 * a resting character can still breathe and blink; what it stops doing is leaving its spot.
 */
export function withoutLayerTravel<T extends Pick<PlanV1, "layers" | "configuration">>(plan: T): T {
  const strip = <A extends { type: string }>(animations: readonly A[] | undefined) => (
    animations?.filter((animation) => !TRAVELLING_SPEC_TYPES.has(animation.type))
  );
  const configuration = plan.configuration && {
    ...plan.configuration,
    variants: plan.configuration.variants.map((variant) => ({
      ...variant,
      layers: variant.layers.map((layer) => (
        layer.animations ? { ...layer, animations: strip(layer.animations) } : layer
      )),
    })),
  };
  return {
    ...plan,
    layers: plan.layers.map((layer) => ({ ...layer, animations: strip(layer.animations) ?? [] })),
    ...(configuration ? { configuration } : {}),
  };
}

/** Ensures the selected preset produces real, selectable clips on every character. */
export function assertPlanPosePreset(plan: Pick<PlanV1, "layers" | "configuration" | "configurationChanges" | "baseRevisionId">, preset: PosePreset): void {
  assertControllablePlan(plan);
  const count = POSE_COUNTS[preset];
  for (const { layer, source } of planSpriteLayers(plan)) {
    const selectable = new Set((plannedConfiguration(plan)?.variants ?? []).flatMap((variant) =>
      variant.layers.filter((patch) => patch.layerId === layer.layerId && patch.clip !== undefined).map((patch) => patch.clip)));
    if (source.clips.length !== count || source.clips.some((clip) => !selectable.has(clip.id))) {
      throw new Error(`The ${preset} pose preset requires exactly ${count} distinct body clips per character, including idle. Give ${layer.name} matching pose options and a variant binding for every clip. Keep facial expressions and frame timing separate.`);
    }
  }
}

/**
 * Every sprite names the one region its facial features share.
 *
 * A character whose eyes sit on a windshield and whose mouth sits on a bumper cannot be built: the
 * body sheet gets one face opening, so whatever facial feature lands outside it stays on the body
 * and is drawn a second time by the expression plate. Checked on the drafting path only, not from
 * the schema, so plans stored before `face` existed still parse. The message is the planner's
 * repair instruction, returned from `create_plan` / `update_plan` like `assertControllablePlan`'s.
 */
export function assertSpriteFaces(plan: Pick<PlanV1, "layers">): void {
  const missing = planSpriteLayers(plan).filter(({ source }) => !source.face);
  if (!missing.length) return;
  throw new Error(
    `Sprite ${missing.map(({ layer }) => layer.layerId).join(", ")} ${missing.length > 1 ? "need" : "needs"} \`face\`: `
    + "one sentence naming the single contiguous region that holds ALL of the character's eyes, brows, nose and mouth, "
    + "and what is in it (e.g. \"the windshield: both eyes and the mouth are inside the glass; grille and bumper carry no "
    + "facial features\"). Never split the face across two areas. The conceptPrompt must describe the face the same way.",
  );
}

/**
 * Rejects a plan that does not build the controllable character the project was created for.
 *
 * The user asked for switchable moods and poses with a toggle rather than with words, so the
 * requirement is the project's, not a sentence in the transcript the planner may read past. Without
 * this the flag would be a suggestion: the model would occasionally answer a mood request with three
 * separately drawn stills, which is the exact shape the sprite layer exists to replace.
 *
 * A sprite alone is not enough — one that nothing selects between is an animation with a single
 * clip. At least one choice control has to bind the layer's `clip` or `expression`, which is what
 * puts the picker in the controls sheet.
 *
 * The message is the model's repair instruction: it is returned from the `create_plan` tool, and the
 * planner is told to fix what the error describes with `update_plan`.
 */
export function assertControllablePlan(plan: Pick<PlanV1, "layers" | "configuration" | "configurationChanges" | "baseRevisionId">): void {
  const sprites = planSpriteLayers(plan);
  if (sprites.length === 0 && !plan.baseRevisionId) {
    throw new Error(
      "This project is controllable: every character needs a layer with a sprite source — a still, "
      + "named body clips, and a strip of face expressions — so the user can switch mood and pose. "
      + "Re-plan the characters as sprites rather than as separately drawn stills.",
    );
  }
  // Every sprite, not merely some sprite: a second character the user can see but cannot pose is
  // the more confusing half-built outcome, and it is the one a plan drifts into.
  const bound = new Set((plannedConfiguration(plan)?.variants ?? []).flatMap((variant) => variant.layers.flatMap((patch) => (
    patch.clip !== undefined || patch.expression !== undefined ? [patch.layerId] : []
  ))));
  // All of them at once, not the first: a three-character plan that binds only the cat would
  // otherwise cost a repair round trip per character.
  const unbound = sprites.filter(({ layer }) => !bound.has(layer.layerId));
  if (unbound.length) {
    throw new Error(
      `${unbound.length > 1 ? "Sprites" : "Sprite"} ${unbound.map(({ layer }) => layer.layerId).join(", ")} `
      + `${unbound.length > 1 ? "have" : "has"} no controls: add a choice control per character whose variants `
      + "bind clip (a pose picker) or expression (a mood picker) on it, one variant per option, each with its own control id.",
    );
  }
}

/**
 * Rejects a plan that builds a controllable character the project did not ask for.
 *
 * The mirror of `assertControllablePlan`, and it exists because that check only ever ran in one
 * direction: a controllable project was made to build sprites, but a plain one was never stopped
 * from building them anyway. The planner is told to reach for a sprite "whenever the user asks for
 * a character whose moods, expressions, emotions, poses, or actions can be switched", so a request
 * like "a cat that waves and smiles" produced a controllable sticker from a user who had left the
 * switch off.
 *
 * That is not only the wrong shape. A sprite costs `1 + clips + 1` image generations against one
 * for an ordinary layer, so an unrequested one quietly charges several times what the user agreed
 * to — which is why the switch wins over anything the prompt implies, rather than being treated as
 * a default the wording can talk its way past.
 *
 * Controls themselves are left alone. A toggle that hides a layer or a control that swaps a caption
 * costs no artwork and builds no character, so only `clip` and `expression` bindings — the two that
 * exist to pose a sprite — are refused alongside the sprite layers.
 */
export function assertNonControllablePlan(
  plan: Pick<PlanV1, "layers" | "configuration" | "configurationChanges" | "baseRevisionId">,
): void {
  const sprites = planSpriteLayers(plan);
  if (sprites.length) {
    throw new Error(
      `${sprites.length > 1 ? "Layers" : "Layer"} ${sprites.map(({ layer }) => layer.layerId).join(", ")} `
      + `${sprites.length > 1 ? "use" : "uses"} a sprite source, but this project is not controllable: the user left `
      + "the moods-and-poses switch off, and a sprite costs several extra image generations they did not ask for. "
      + "Re-plan the characters with generate sources — one drawing each, in the single pose the request describes — "
      + "and express any movement with animations instead of selectable body clips.",
    );
  }
  const posed = (plannedConfiguration(plan)?.variants ?? []).flatMap((variant) => variant.layers.flatMap((patch) => (
    patch.clip !== undefined || patch.expression !== undefined ? [patch.layerId] : []
  )));
  if (posed.length) {
    throw new Error(
      `${[...new Set(posed)].join(", ")} ${posed.length > 1 ? "bind" : "binds"} clip or expression, which only a sprite `
      + "can answer, and this project is not controllable. Drop those bindings. Controls that hide a layer or change "
      + "text are still fine.",
    );
  }
}

/**
 * Rejects a plan the job that is drafting it could not build.
 *
 * A quick turn is the Messages extension's path, and its stickers are rendered on the server —
 * which can draw a still for every layer type but cannot decode a clip. A video layer planned there
 * would build a sticker whose one moving part is frozen in Messages. Refused at draft time so the
 * model repairs the plan in the same conversation instead of the user confirming a broken one.
 */
export function assertPlanAllowedForJob(plan: Pick<PlanV1, "layers">, job: { quick: boolean }): void {
  if (!job.quick) return;
  const videos = plan.layers.filter((layer) => layer.source.kind === "video");
  if (videos.length > 0) {
    throw new Error(
      `Video layers are not available in quick mode: ${videos.map((layer) => layer.layerId).join(", ")}. `
        + "Draw each one with a generate source and express its motion with animations instead.",
    );
  }
  // The quick model draws against a chroma backdrop that is keyed out afterwards; a sprite sheet
  // needs a second flat colour for its face slot, and a grid of cells besides, neither of which that
  // key can tell apart from the backdrop.
  const sprites = planSpriteLayers(plan);
  if (sprites.length > 0) {
    throw new Error(
      `Sprite characters are not available in quick mode: ${sprites.map(({ layer }) => layer.layerId).join(", ")}. `
        + "Draw the character with a generate source instead.",
    );
  }
}

/**
 * Whether this plan needs an approved static reference rendered before it can be built.
 *
 * Every animated plan does, with one exception: a plan led by captured footage that draws nothing.
 * The concept exists so generated artwork can inherit an approved silhouette, and it doubles as the
 * preview on the plan card. A capture-led plan with `generate` layers still needs one, because those
 * layers do have something to match. A capture-led plan without them has neither reason — asking the
 * image model to redraw the user's own face would cost a generation to produce something strictly
 * worse than the photograph already in hand.
 *
 * Three places consult this and must agree, or a plan the user confirmed fails at build time over a
 * reference that was deliberately never made: `confirmPlan`, `planReferencePrompt`, and
 * `executePlanBuildTurn`.
 */
export function planRequiresConcept(plan: Pick<PlanV1, "kind" | "layers" | "configuration" | "configurationChanges" | "baseRevisionId">): boolean {
  if (plan.kind !== "animated") return false;
  if (plan.baseRevisionId) return planGenerationCount(plan) > 0;
  const capturesSubject = plan.layers.some((layer) => layer.source.kind === "sequence");
  return !capturesSubject || planGenerationCount(plan) > 0;
}

/**
 * Keeps an animated build visually tied to the still image the user approved.
 *
 * Text, shape, and particle sources are rendered independently by the app. They are useful for
 * static plans, but they cannot inherit the illustration model's exact silhouette, outline,
 * highlights, shadows, or texture from an approved reference. New animated artwork therefore uses
 * generated image layers; existing image layers remain valid because they already have pixels to
 * preserve.
 *
 * `sequence` is exempt for the same reason `existing` is, only more so: it is not app-rendered at
 * all. It is photographic frames the user captured, which is the highest-fidelity source in the
 * whole vocabulary — there is nothing for it to fail to match, because it *is* the reference.
 *
 * `video` is reference-backed: its clip is animated from a still separated from the approved
 * image, so it inherits that image's look the same way a generate layer does.
 */
export function assertAnimatedPlanUsesReferenceBackedArtwork(plan: PlanV1): void {
  if (plan.kind !== "animated" || plan.baseRevisionId) return;
  // A capture-led plan has no generated concept to diverge from — the footage *is* the reference,
  // and the build path skips concept rendering for exactly that reason. With nothing to match, this
  // rule has no work to do, and enforcing it anyway would forbid the sparkles and captions that are
  // the whole point of decorating a lifted subject.
  if (plan.layers.some((layer) => layer.source.kind === "sequence")) return;
  const appRendered = plan.layers.filter((layer) => (
    layer.source.kind === "text" || layer.source.kind === "shape" || layer.source.kind === "particle"
  ));
  if (appRendered.length === 0) return;

  const named = appRendered.map((layer) => `${layer.layerId} (${layer.source.kind})`).join(", ");
  throw new Error(
    `These animated layers use app-rendered primitives that cannot match the approved static reference: ${named}. `
      + "Use a generate source for each one so the image model can separate its exact appearance "
      + "from the reference. Existing image sources may still be reused.",
  );
}

/**
 * The artwork a plan may reuse: every image and capture layer the sticker on screen already has.
 *
 * Capture layers are included deliberately. Footage the user lifted from their own Live Photo is
 * the one thing in a document that cannot be regenerated at any price, so a re-plan that dropped it
 * would quietly replace the user's face with something drawn from a prompt.
 */
export function reusableAssetIds(document?: StickerDocument): string[] {
  return document ? documentRenderableLayers(document).flatMap((layer) => (
    layer.type === "image" || layer.type === "sequence" ? [layer.assetId] : []
  )) : [];
}

/**
 * Rejects a plan that reuses artwork this sticker does not have.
 *
 * Enforced here rather than in the schema because only the drafting turn knows which document the
 * plan is being written against. The message names the ids that would have worked, so the model can
 * repair the plan in the same conversation instead of the reuse failing at build time — long after
 * the user confirmed it.
 */
export function assertPlanReuseIsResolvable(
  plan: Pick<PlanV1, "layers" | "configuration" | "configurationChanges" | "baseRevisionId">,
  document?: StickerDocument,
  /**
   * Capture atlases attached to the message being planned against.
   *
   * A `sequence` source names an asset that is usually *not* in the current document yet — it came
   * in on this turn — so it cannot be resolved against the document alone the way `existing` is.
   */
  attachedSequenceAssetIds: readonly string[] = [],
): void {
  const available = new Set(reusableAssetIds(document));
  const resolvableCaptures = new Set([...available, ...attachedSequenceAssetIds]);
  const unknown = plan.layers.filter((layer) => (
    (layer.source.kind === "existing" && !available.has(layer.source.assetId))
    || (layer.source.kind === "sequence" && !resolvableCaptures.has(layer.source.assetId))
  ));
  for (const variant of plannedConfiguration(plan)?.variants ?? []) for (const patch of variant.layers) {
    if ((patch.source?.kind === "existing" || patch.source?.kind === "sequence") && !available.has(patch.source.assetId)) throw new Error(`Variant ${variant.id} reuses unavailable artwork ${patch.source.assetId}`);
  }
  if (unknown.length === 0) return;
  const named = unknown
    .map((layer) => `${layer.layerId} (${(layer.source as { assetId: string }).assetId})`)
    .join(", ");
  throw new Error(
    available.size > 0
      ? `These layers reuse artwork the current sticker does not have: ${named}. `
        + `The assetIds you may reuse are: ${[...available].join(", ")}. `
        + "Use them exactly as written, or draw the layer with a generate source instead."
      : `These layers reuse artwork that does not exist: ${named}. The current sticker has no `
        + "image layers, so every drawn layer must use a generate source.",
  );
}

// --- user edits ------------------------------------------------------------------------------
//
// The plan card is editable in the app: the user can retype a layer's description, switch it
// between drawn artwork and a video clip, add and remove layers and motion, and change the timing.
//
// The request is deliberately *not* a whole plan. A plan carries far more than the card shows —
// a text layer's font and alignment, a capture's frame grid, every parameter of a `spin` or a
// `shine` — and a client that posted back only what it renders would silently flatten all of it.
// So an edit names what to keep (`from`) and states only what changed, and the server rebuilds the
// plan from the stored one. Anything the editor cannot express survives untouched.

/** The layer sources the app's plan editor can author. Everything else is kept, never written. */
export const EditablePlanLayerSourceV1Schema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("generate"),
    prompt: z.string().trim().min(1).max(2_000),
  }).strict(),
  z.object({
    kind: z.literal("video"),
    prompt: z.string().trim().min(1).max(2_000),
    motion: z.string().trim().min(1).max(500),
    durationSeconds: z.number().int().min(2).max(4).default(3),
  }).strict(),
]);

/**
 * The motion effects the editor offers, as a flat list a picker can render.
 *
 * A subset of `AnimationSpecV1Schema` on purpose: every type here is either parameterless or takes
 * a direction, so it can be added with one tap and no numeric fields. The rest — `moveTo`,
 * `scaleTo`, `hueShift`, the trim specs — need coordinates or a target only the planner has, and a
 * plan that already carries one keeps it, because an edit that does not mention an animation never
 * rewrites it.
 */
export const EDITABLE_ANIMATION_TYPES = [
  "fadeIn", "fadeOut", "popIn", "popOut", "slideIn", "slideOut",
  "spin", "wiggle", "pulse", "bounce", "float",
  "blurIn", "blurOut", "wipeIn", "wipeOut",
  "shine", "bloomIn", "bloomOut", "bloomPulse",
] as const;

/** Types from that list whose spec has a required `direction`. */
export const DIRECTIONAL_ANIMATION_TYPES = ["slideIn", "slideOut", "wipeIn", "wipeOut"] as const;

export const EditableAnimationSpecV1Schema = z.object({
  type: z.enum(EDITABLE_ANIMATION_TYPES),
  delay: z.number().min(0).max(MAX_TIME_SECONDS).default(0),
  duration: z.number().min(0.05).max(MAX_TIME_SECONDS).default(0.5),
  /** Required by the directional types above, rejected by the rest. */
  direction: z.enum(["up", "down", "left", "right"]).optional(),
}).strict();

/**
 * One motion effect in the edited layer: either one the plan already had, or a new one.
 *
 * `from` is an index into the *original* layer's animations rather than an id, because specs have
 * no identity of their own. It is resolved against the stored plan, so removals and additions in
 * the same request cannot shift each other's meaning.
 */
export const PlanAnimationEditV1Schema = z.object({
  from: z.number().int().min(0).max(11).nullish().default(null),
  spec: EditableAnimationSpecV1Schema.optional(),
  /** Retimes a kept effect. Ignored for a new one, which carries its own timing in `spec`. */
  delay: z.number().min(0).max(MAX_TIME_SECONDS).optional(),
  duration: z.number().min(0.05).max(MAX_TIME_SECONDS).optional(),
}).strict().superRefine((entry, context) => {
  if (entry.from == null && !entry.spec) {
    context.addIssue({ code: "custom", message: "A new animation needs a spec" });
  }
});

/**
 * One layer of the edited plan.
 *
 * `from` names the layer of the stored plan this entry keeps; every other field is an override on
 * it, so an entry of `{ from: "part_0" }` is "leave this layer exactly as it is". A `from` of null
 * is a layer the user added, and then the identity, name, and source are required.
 */
export const PlanLayerEditV1Schema = z.object({
  from: LayerIdSchema.nullish().default(null),
  layerId: LayerIdSchema.optional(),
  name: z.string().trim().min(1).max(80).optional(),
  source: EditablePlanLayerSourceV1Schema.optional(),
  x: z.number().min(0).max(1).optional(),
  y: z.number().min(0).max(1).optional(),
  scaleX: z.number().min(0.05).max(1).optional(),
  scaleY: z.number().min(0.05).max(1).optional(),
  rotationDegrees: z.number().min(-180).max(180).optional(),
  /** Present only when the motion changed: absent keeps the layer's effects untouched. */
  animations: z.array(PlanAnimationEditV1Schema).max(12).optional(),
}).strict().superRefine((entry, context) => {
  if (entry.from != null) return;
  if (!entry.layerId) context.addIssue({ code: "custom", path: ["layerId"], message: "A new layer needs a layerId" });
  if (!entry.name) context.addIssue({ code: "custom", path: ["name"], message: "A new layer needs a name" });
  if (!entry.source) context.addIssue({ code: "custom", path: ["source"], message: "A new layer needs a source" });
});

/**
 * What the user changed about a plan. Every field is optional; an omitted one is unchanged.
 *
 * `layers`, when present, is the complete new list in order — that single shape covers reordering,
 * removal, and addition without three operations that could contradict one another.
 */
export const PlanEditV1Schema = z.object({
  configuration: PlanConfigurationSchema.nullable().optional(),
  clearConfiguration: z.boolean().optional(),
  title: z.string().trim().min(1).max(120).optional(),
  summary: z.string().trim().min(1).max(1_000).optional(),
  timing: z.object({
    durationSeconds: z.number().min(0.5).max(4).optional(),
    fps: z.number().int().min(1).max(30).optional(),
    loop: z.enum(["once", "loop", "pingPong"]).optional(),
  }).strict().optional(),
  layers: z.array(PlanLayerEditV1Schema).min(1).max(8).optional(),
}).strict();

export type EditablePlanLayerSourceV1 = z.infer<typeof EditablePlanLayerSourceV1Schema>;
export type PlanAnimationEditV1 = z.infer<typeof PlanAnimationEditV1Schema>;
export type PlanLayerEditV1 = z.infer<typeof PlanLayerEditV1Schema>;
export type PlanEditV1 = z.infer<typeof PlanEditV1Schema>;

function resolveEditedAnimation(
  base: readonly AnimationSpecV1[],
  entry: PlanAnimationEditV1,
  layerId: string,
): AnimationSpecV1 {
  if (entry.from == null) {
    // Optional keys the client left out arrive as absent rather than undefined, but a client that
    // sends `direction: undefined` explicitly would trip the strict spec schemas, so drop them.
    const fields = Object.fromEntries(
      Object.entries(entry.spec ?? {}).filter(([, value]) => value !== undefined),
    );
    return AnimationSpecV1Schema.parse(fields);
  }
  const existing = base[entry.from];
  if (!existing) {
    throw new Error(`Layer ${layerId} has no animation at index ${entry.from} to keep.`);
  }
  return {
    ...existing,
    ...(entry.delay === undefined ? {} : { delay: entry.delay }),
    ...(entry.duration === undefined ? {} : { duration: entry.duration }),
  };
}

/**
 * Rebuilds a plan from the stored one plus the user's edit.
 *
 * Throws a plain `Error` for an edit that cannot be applied at all — a `from` naming a layer that
 * is not there. An edit that applies but produces an invalid plan is caught by `PlanV1Schema`
 * instead, whose messages already say what is wrong with a plan.
 */
export function applyPlanEdit(current: PlanV1, edit: PlanEditV1): PlanV1 {
  const byId = new Map(current.layers.map((layer) => [layer.layerId, layer]));
  const layers = edit.layers?.map((entry) => {
    if (entry.from == null) {
      return PlanLayerV1Schema.parse({
        layerId: entry.layerId,
        name: entry.name,
        source: EditablePlanLayerSourceV1Schema.parse(entry.source),
        x: entry.x ?? 0.5,
        y: entry.y ?? 0.5,
        scaleX: entry.scaleX ?? 0.4,
        scaleY: entry.scaleY ?? 0.4,
        rotationDegrees: entry.rotationDegrees ?? 0,
        animations: (entry.animations ?? []).map((animation) => (
          resolveEditedAnimation([], animation, entry.layerId ?? "new")
        )),
      });
    }
    const base = byId.get(entry.from);
    if (!base) throw new Error(`This plan has no layer called ${entry.from} to edit.`);
    return {
      ...base,
      name: entry.name ?? base.name,
      source: entry.source ?? base.source,
      x: entry.x ?? base.x,
      y: entry.y ?? base.y,
      scaleX: entry.scaleX ?? base.scaleX,
      scaleY: entry.scaleY ?? base.scaleY,
      rotationDegrees: entry.rotationDegrees ?? base.rotationDegrees,
      animations: entry.animations
        ? entry.animations.map((animation) => resolveEditedAnimation(base.animations, animation, base.layerId))
        : base.animations,
    };
  }) ?? current.layers;

  const summary = edit.summary ?? current.summary;
  // `PlanV1Schema` requires the summary to mention a video layer, because the summary *is* the
  // assistant's chat message and a clip costs more than drawn artwork. The model is told to write
  // that sentence; a user who turns a layer into a clip cannot be, so it is added for them rather
  // than bounced back as a validation error about prose they never wrote.
  const mentionsVideo = /\bvideo\b/i.test(summary);
  const hasVideo = layers.some((layer) => layer.source.kind === "video");

  return PlanV1Schema.parse({
    ...current,
    title: edit.title ?? current.title,
    summary: hasVideo && !mentionsVideo
      ? `${summary} One layer is generated as a short video clip.`
      : summary,
    timing: { ...current.timing, ...edit.timing },
    configuration: configurationKeepingLayers(edit.clearConfiguration ? undefined : edit.configuration === undefined ? current.configuration : edit.configuration ?? undefined,
      new Set(layers.map((layer) => layer.layerId))),
    layers,
  });
}
