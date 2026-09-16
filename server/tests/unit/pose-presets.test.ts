import { describe, expect, it } from "vitest";
import { CreateStickerRequestSchema, PostChatMessageRequestSchema } from "@/lib/contracts/api";
import { assertPlanPosePreset, PlanV1Schema, planGenerationCount, type PlanV1 } from "@/lib/contracts/plan";
import { POSE_COUNTS, type PosePreset } from "@/lib/contracts/pose-preset";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import type { PlanDraftingSession } from "@/lib/ai/gateway-contracts";

async function presetPlan(posePreset: PosePreset): Promise<PlanV1> {
  let result: PlanV1 | undefined;
  const session = {
    createPlan: async (plan: PlanV1) => { result = plan; return { planId: "test-plan", revision: 1 }; },
    finalizePlan: async () => ({ planId: "test-plan", revision: 1 }),
    updatePlan: async () => ({ planId: "test-plan", revision: 1 }),
    showPlan: async () => ({ planId: "test-plan", revision: 1 }),
  } as PlanDraftingSession;
  await new MockAiProvider().planSticker({ instruction: "A happy cat", history: "", stickerKind: "animated", controllable: true,
    posePreset, rejectedReasons: [], sequenceAssets: [], references: [], priorArt: [] }, session);
  return result!;
}

describe("pose presets", () => {
  it.each(Object.entries(POSE_COUNTS))("%s generates %s selectable poses per character", async (preset, count) => {
    const plan = await presetPlan(preset as PosePreset);
    expect(plan.layers[0].source.kind).toBe("sprite");
    if (plan.layers[0].source.kind !== "sprite") throw new Error("Missing sprite");
    expect(plan.layers[0].source.clips).toHaveLength(count);
    expect(plan.layers[0].source.expressions).toHaveLength(3);
    expect(plan.layers[0].source.clips.every((clip) => clip.frames.length === 6)).toBe(true);
    expect(planGenerationCount(plan)).toBe(count + 2);
    expect(() => assertPlanPosePreset(plan, preset as PosePreset)).not.toThrow();
    expect(PlanV1Schema.parse(plan).posePreset).toBe(preset);
  });

  it("refuses wrong counts and unselectable poses, including manual plan edits", async () => {
    const plan = await presetPlan("low");
    expect(PlanV1Schema.safeParse({ ...plan, posePreset: "ultra" }).success).toBe(false);
    plan.configuration!.variants = plan.configuration!.variants.filter((variant) => variant.id !== "wave");
    expect(() => assertPlanPosePreset(plan, "low")).toThrow(/variant binding/);
    expect(PlanV1Schema.safeParse(plan).success).toBe(false);
  });

  it("accepts labels only and only for controllable animation creation", () => {
    const request = { title: "Cat", prompt: "Cat", kind: "animated", controllable: true, posePreset: "medium" };
    expect(CreateStickerRequestSchema.parse(request).posePreset).toBe("medium");
    for (const change of [{ posePreset: 5 }, { posePreset: "custom" }, { kind: "static" }, { controllable: false }, { quick: true }]) {
      expect(CreateStickerRequestSchema.safeParse({ ...request, ...change }).success).toBe(false);
    }
    expect(CreateStickerRequestSchema.parse({ title: "Legacy", prompt: "Legacy", kind: "animated" }).posePreset).toBeUndefined();
  });

  it("requires an explicit plan version for updates and rejects conflicting intents", () => {
    const request = { text: "Update plan", intent: "chat", planPoseUpdate: {
      planId: "11111111-1111-4111-8111-111111111111", currentRevision: 1, posePreset: "high",
    } };
    expect(PostChatMessageRequestSchema.parse(request).planPoseUpdate?.posePreset).toBe("high");
    for (const change of [{ intent: "edit" }, { quick: true }, { targetLayerId: "hero" }, { planPoseUpdate: { posePreset: "high" } }]) {
      expect(PostChatMessageRequestSchema.safeParse({ ...request, ...change }).success).toBe(false);
    }
  });
});
