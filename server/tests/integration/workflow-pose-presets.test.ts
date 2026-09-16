import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiChatContext, type AiPlanContext, type PlanDraftingSession } from "@/lib/ai/gateway";
import { setDatabaseForTests } from "@/lib/db/client";
import { plans, stickers, users } from "@/lib/db/schema";
import { createChatTurn, createSticker, listChatMessages } from "@/lib/services/stickers";
import { selectPlanVersion } from "@/lib/services/plans";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

describe("pose preset planning workflow", () => {
  afterEach(resetWorkflowTestState);

  it("persists creation, explicitly replans to Ultra, rejects stale updates and restores the earlier preset", async () => {
    const { db, close } = await createTestDatabase();
    try {
      setDatabaseForTests(db);
      setObjectStoreForTests(new MemoryObjectStore());
      process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
      let routerCalls = 0;
      const planningHistory: string[] = [];
      class Provider extends MockAiProvider {
        override async planSticker(input: AiPlanContext, session: PlanDraftingSession) {
          planningHistory.push(input.history);
          return super.planSticker(input, session);
        }
        override async routeChatTurn(input: AiChatContext) {
          routerCalls += 1;
          return { type: "plan" as const, instruction: input.instruction };
        }
      }
      setAiProviderForTests(new Provider());
      await db.insert(users).values({ id: "owner-poses" });
      const sticker = await createSticker(db, "owner-poses", { title: "Cat", kind: "animated", prompt: "Cat", controllable: true,
        posePreset: "low", referenceAssetIds: [] });
      const initial = await createChatTurn(db, "owner-poses", sticker.stickerId, {
        text: "A happy cat", intent: "generate", attachments: [], imagePlacement: "replace",
      });
      await stickerGenerationWorkflow(initial.jobId);
      const before = (await listChatMessages(db, "owner-poses", sticker.stickerId)).data.find((message) => message.plan)?.plan;
      expect(before?.plan.posePreset).toBe("low");
      expect(before?.generationCount).toBe(4);
      const update = { text: "Update this plan with Ultra pose variety", intent: "chat" as const, attachments: [], imagePlacement: "replace" as const,
        planPoseUpdate: { planId: before!.id, currentRevision: before!.revision, posePreset: "ultra" as const, edit: { title: "Edited in the layer editor" } } };
      await expect(createChatTurn(db, "owner-poses", sticker.stickerId, {
        ...update, planPoseUpdate: { ...update.planPoseUpdate, edit: {
          title: "Must roll back", clearConfiguration: true,
          layers: [{ from: "hero", source: { kind: "generate", prompt: "A static cat" } }],
        } },
      })).rejects.toMatchObject({ code: "PLAN_EDIT_INVALID" });
      expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)))[0].posePreset).toBe("low");
      expect((await db.select().from(plans).where(eq(plans.id, before!.id)))[0].state).toBe("finalized");
      const next = await createChatTurn(db, "owner-poses", sticker.stickerId, update);
      await stickerGenerationWorkflow(next.jobId);
      const after = (await listChatMessages(db, "owner-poses", sticker.stickerId)).data.filter((message) => message.plan).at(-1)?.plan;
      expect(after?.plan.posePreset).toBe("ultra");
      expect(planningHistory.at(-1)).toContain("Edited in the layer editor");
      expect(after?.generationCount).toBe(10);
      expect(after?.id).not.toBe(before?.id);
      expect(routerCalls).toBe(0);
      expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)))[0].posePreset).toBe("ultra");
      expect((await db.select().from(plans).where(eq(plans.id, before!.id)))[0].planJson.posePreset).toBe("low");
      await expect(createChatTurn(db, "owner-poses", sticker.stickerId, update)).rejects.toMatchObject({ code: "PLAN_CHANGED" });
      const restored = await selectPlanVersion(db, "owner-poses", sticker.stickerId, before!.id, after!.id, after!.revision);
      expect(restored.plan.plan.posePreset).toBe("low");
      expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)))[0].posePreset).toBe("low");
    } finally { await close(); }
  }, 120_000);
});
