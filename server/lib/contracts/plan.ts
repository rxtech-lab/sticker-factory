import { z } from "zod";
import {
  compileLayerAnimations,
  type AnimationTiming,
  type LayerCompileInput,
} from "@/lib/animation/compile";
import { AnimationSpecV1Schema, type AnimationAnchorV1 } from "@/lib/contracts/animation";
import { LayerIdSchema } from "@/lib/contracts/sticker";

const HexColorSchema = z.string().regex(/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/);

/**
 * Where a planned layer's content comes from.
 *
 * Only `generate` costs an image generation. Text, shape, and particle layers are assembled
 * directly from the plan, which is why a plan can be far cheaper than its layer count suggests.
 */
export const PlanLayerSourceV1Schema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("generate"),
    /** Describes one element filling its frame on a transparent background. */
    prompt: z.string().trim().min(1).max(2_000),
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
   * How to draw the concept storyboard the user approves before anything is generated.
   *
   * Optional because a plan is still actionable without a picture — concept rendering is a
   * best-effort step and plans stored before it existed must keep parsing.
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
