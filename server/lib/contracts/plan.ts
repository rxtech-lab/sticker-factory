import { z } from "zod";
import {
  compileLayerAnimations,
  type AnimationTiming,
  type LayerCompileInput,
} from "@/lib/animation/compile";
import { AnimationSpecV1Schema, type AnimationAnchorV1 } from "@/lib/contracts/animation";
import { LayerIdSchema, type StickerDocument } from "@/lib/contracts/sticker";

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
]);

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
}).strict();

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
  version: z.literal(1).default(1),
  title: z.string().trim().min(1).max(120),
  /** Shown to the user as the assistant's chat message: one or two friendly sentences. */
  summary: z.string().trim().min(1).max(1_000),
  kind: z.enum(["static", "animated"]),
  timing: PlanTimingV1Schema.default({ durationSeconds: 2, fps: 30, loop: "loop" }),
  layers: z.array(PlanLayerV1Schema).min(1).max(8),
  /**
   * How to draw the finished static reference the user approves before animated parts are made.
   *
   * Older plans may not carry this field, so it remains optional in the persisted v1 schema. The
   * workflow derives a complete fallback prompt for animated plans, which means every new animated
   * plan still has a reference image before it becomes actionable.
   */
  conceptPrompt: z.string().trim().min(1).max(2_000).optional(),
}).strict().superRefine((plan, context) => {
  const ids = new Set<string>();
  for (const layer of plan.layers) {
    if (ids.has(layer.layerId)) {
      context.addIssue({ code: "custom", message: `Duplicate plan layer id: ${layer.layerId}` });
    }
    ids.add(layer.layerId);
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

/** The resting state a planned layer's motion departs from and returns to. */
export function planLayerAnchor(layer: PlanLayerV1): AnimationAnchorV1 {
  return {
    position: { x: layer.x, y: layer.y },
    scale: { x: layer.scaleX, y: layer.scaleY },
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

/** How many image generations executing this plan will cost. */
export function planGenerationCount(plan: Pick<PlanV1, "layers">): number {
  return plan.layers.filter((layer) => layer.source.kind === "generate").length;
}

/**
 * Keeps an animated build visually tied to the still image the user approved.
 *
 * Text, shape, and particle sources are rendered independently by the app. They are useful for
 * static plans, but they cannot inherit the illustration model's exact silhouette, outline,
 * highlights, shadows, or texture from an approved reference. New animated artwork therefore uses
 * generated image layers; existing image layers remain valid because they already have pixels to
 * preserve.
 */
export function assertAnimatedPlanUsesReferenceBackedArtwork(plan: PlanV1): void {
  if (plan.kind !== "animated") return;
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

/** The artwork a plan may reuse: every image layer the sticker on screen already has. */
export function reusableAssetIds(document?: Pick<StickerDocument, "layers">): string[] {
  return document?.layers.flatMap((layer) => (layer.type === "image" ? [layer.assetId] : [])) ?? [];
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
  plan: Pick<PlanV1, "layers">,
  document?: Pick<StickerDocument, "layers">,
): void {
  const available = new Set(reusableAssetIds(document));
  const unknown = plan.layers.filter(
    (layer) => layer.source.kind === "existing" && !available.has(layer.source.assetId),
  );
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
