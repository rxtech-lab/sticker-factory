import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiChatContext, type AiPlanContext, type AiLayoutContext, type AiImageInput, type LayoutDraftingSession, type PlanDraftingSession } from "@/lib/ai/gateway";
import { creationPresetCatalog } from "@/lib/creation-presets/catalog";
import { setDatabaseForTests } from "@/lib/db/client";
import { stickers, users } from "@/lib/db/schema";
import { createSticker, createChatTurn, getSticker, listChatMessages } from "@/lib/services/stickers";
import { confirmPlan } from "@/lib/services/plans";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

const presets = { catalogVersion: creationPresetCatalog.version, selections: [
  { groupId: "style", optionIds: ["clay"] }, { groupId: "theme", optionIds: ["space", "cozy"] },
] };
describe("saved creation presets", () => {
  afterEach(resetWorkflowTestState);
  it("requires an animated controllable sticker for Pet Companion", async () => {
    const { db, close } = await createTestDatabase();
    try {
      await db.insert(users).values({ id: "pet-style-owner" });
      const petPresets = { catalogVersion: creationPresetCatalog.version, selections: [
        { groupId: "style", optionIds: ["pet-companion"] },
      ] };
      const request = { title: "Cat", prompt: "A friendly cat", referenceAssetIds: [], presets: petPresets };
      await expect(createSticker(db, "pet-style-owner", { ...request, kind: "static" }))
        .rejects.toMatchObject({ code: "PET_STYLE_REQUIRES_CONTROLS" });
      await expect(createSticker(db, "pet-style-owner", { ...request, kind: "animated" }))
        .rejects.toMatchObject({ code: "PET_STYLE_REQUIRES_CONTROLS" });
      expect(await db.select().from(stickers)).toHaveLength(0);
      const created = await createSticker(db, "pet-style-owner", {
        ...request, kind: "animated", controllable: true, posePreset: "medium",
      });
      const saved = (await db.select().from(stickers).where(eq(stickers.id, created.stickerId)))[0];
      expect(saved.kind).toBe("animated");
      expect(saved.controllable).toBe(true);
      expect(saved.creationPresets?.selections[0].options[0].id).toBe("pet-companion");
    } finally { await close(); }
  });
  it("validates before creating a project and preserves the display snapshot on reopen", async () => {
    const { db, close } = await createTestDatabase();
    try {
      await db.insert(users).values({ id: "preset-owner" });
      const request = { title: "Cat", kind: "animated" as const, prompt: "Cat", referenceAssetIds: [], presets };
      await expect(createSticker(db, "preset-owner", { ...request, presets: { ...presets, selections: [] } })).rejects.toMatchObject({ code: "INVALID_CREATION_PRESETS" });
      expect(await db.select().from(stickers)).toHaveLength(0);
      const created = await createSticker(db, "preset-owner", request);
      const detail = await getSticker(db, "preset-owner", created.stickerId);
      expect(detail.presets?.selections[0].options[0].title.en).toBe("3D Clay");
      expect(JSON.stringify(detail.presets)).not.toContain('"prompt"');
      const saved = (await db.select().from(stickers).where(eq(stickers.id, created.stickerId)))[0];
      expect(saved.creationPresets?.selections[0].options[0].prompt).toContain("sculpted clay");
    } finally { await close(); }
  }, 120_000);

  it("carries presets into planning, build images, layout and later chat without changing user text", async () => {
    const { db, close } = await createTestDatabase();
    try {
      setDatabaseForTests(db); setObjectStoreForTests(new MemoryObjectStore());
      process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
      const calls: Array<[string, string | undefined]> = [];
      class Provider extends MockAiProvider {
        override async planSticker(input: AiPlanContext, session: PlanDraftingSession) {
          expect(input.presetReferences?.map(v => v.label)).toEqual(["Style: 3D Clay", "Theme: Cozy Days", "Theme: Space"]);
          expect(input.presetReferences?.every(v => v.image.bytes.length > 100)).toBe(true);
          calls.push(["plan", input.presetGuidance]); return super.planSticker(input, session);
        }
        override async routeChatTurn(input: AiChatContext) {
          expect(input.presetReferences).toHaveLength(3);
          calls.push(["chat", input.presetGuidance]); return { type: "reply" as const, message: "Ready for your next change." };
        }
        override async generateStickerImage(input: AiImageInput) {
          expect(input.references.length).toBeGreaterThan(0);
          expect(input.prompt).toContain("preset example board");
          expect(input.references.at(-1)?.label).toContain("preset style example board");
          expect(input.pixelArt).toBe(false);
          calls.push(["image", input.prompt]); return super.generateStickerImage(input);
        }
        override async refineStickerLayout(input: AiLayoutContext, session: LayoutDraftingSession) {
          expect(input.presetReferences).toHaveLength(3);
          calls.push(["layout", input.presetGuidance]); return super.refineStickerLayout(input, session);
        }
      }
      setAiProviderForTests(new Provider());
      await db.insert(users).values({ id: "preset-workflow" });
      const created = await createSticker(db, "preset-workflow", { title: "Cat", kind: "animated", prompt: "A friendly cat", referenceAssetIds: [], presets });
      const turn = await createChatTurn(db, "preset-workflow", created.stickerId, { text: "A friendly cat", intent: "generate", attachments: [], imagePlacement: "replace" });
      await stickerGenerationWorkflow(turn.jobId);
      const plan = (await listChatMessages(db, "preset-workflow", created.stickerId)).data.find((message) => message.plan)?.plan;
      expect(plan).toBeDefined();
      const build = await confirmPlan(db, "preset-workflow", created.stickerId, plan!.id);
      await stickerGenerationWorkflow(build.jobId);
      const followup = await createChatTurn(db, "preset-workflow", created.stickerId, { text: "What should I try next?", intent: "chat", attachments: [], imagePlacement: "replace" });
      await stickerGenerationWorkflow(followup.jobId);
      for (const name of ["plan", "image", "layout", "chat"]) {
        expect(calls.some(([stage, guidance]) => stage === name && guidance?.includes("sculpted clay") && guidance.includes("Space") && guidance.includes("Cozy Days"))).toBe(true);
      }
      const messages = await listChatMessages(db, "preset-workflow", created.stickerId);
      expect(messages.data.find((m) => m.role === "user")?.content).toBe("A friendly cat");
    } finally { await close(); }
  }, 120_000);
});
