import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiPlanContext, type AiChatContext, type AiPlanVisual, type PlanDraftingSession } from "@/lib/ai/gateway";
import { setDatabaseForTests } from "@/lib/db/client";
import { plans, users } from "@/lib/db/schema";
import { confirmPlan, currentPendingPlan, selectPlanVersion } from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { loadPlanAnimationSummary } from "@/workflows/sticker-generation/build-turns";

afterEach(resetWorkflowTestState);

it("carries summary pixels into future chat and replanning, following restored and edited plans", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "summary-chat-owner" });
    const plannerVisuals: AiPlanVisual[][] = [];
    const chatVisuals: AiPlanVisual[][] = [];
    let summaries = 0;
    class Provider extends MockAiProvider {
      override async generateConceptImage(input: Parameters<MockAiProvider["generateConceptImage"]>[0]) {
        if (!input.purpose) return super.generateConceptImage(input);
        const bytes = new Uint8Array(await sharp({ create: {
          width: 1024, height: 1024, channels: 4,
          background: ["red", "green", "blue", "orange"][summaries++ % 4],
        } }).png().toBuffer());
        return { bytes, mimeType: "image/png" as const };
      }
      override async planSticker(input: AiPlanContext, session: PlanDraftingSession) {
        plannerVisuals.push(input.priorArt);
        return super.planSticker(input, session);
      }
      override async routeChatTurn(input: AiChatContext) {
        chatVisuals.push(input.priorArt);
        return { type: "reply" as const, message: "The second pose is a wave." };
      }
    }
    setAiProviderForTests(new Provider());
    const owner = "summary-chat-owner";
    const sticker = await createSticker(db, owner, {
      title: "Cat", kind: "animated", prompt: "A cat", referenceAssetIds: [], controllable: true,
    });
    const turn = async (text: string, intent: "generate" | "chat" = "chat") => {
      const created = await createChatTurn(db, owner, sticker.stickerId, {
        text, intent, attachments: [], imagePlacement: "replace",
      });
      expect((await stickerGenerationWorkflow(created.jobId)).workflowStatus).toBe("succeeded");
    };
    const summaryIn = (visuals: AiPlanVisual[]) => visuals.find((visual) => visual.label.includes("illustrated animation summary"));
    await turn("A cat", "generate");
    const first = (await currentPendingPlan(db, owner, sticker.stickerId))!;
    const firstImage = await loadPlanAnimationSummary(first, owner, sticker.stickerId);
    expect(firstImage).toBeDefined();
    await turn("Make the second pose more enthusiastic");
    expect(summaryIn(plannerVisuals[1])?.image).toEqual(firstImage);
    const second = (await currentPendingPlan(db, owner, sticker.stickerId))!;
    const secondImage = await loadPlanAnimationSummary(second, owner, sticker.stickerId);
    expect(secondImage).not.toEqual(firstImage);
    const build = await confirmPlan(db, owner, sticker.stickerId, second.id);
    expect((await stickerGenerationWorkflow(build.jobId)).workflowStatus).toBe("succeeded");
    await turn("What is the second pose in the animation image?");
    expect(summaryIn(chatVisuals[0])?.image).toEqual(secondImage);
    expect(summaryIn(chatVisuals[0])?.label).toContain("confirmed");
    // Restoring an earlier version must restore its visual context too.
    await selectPlanVersion(db, owner, sticker.stickerId, first.id, second.id, second.revision);
    await turn("Keep the expressions from this version");
    expect(summaryIn(plannerVisuals[2])?.image).toEqual(firstImage);
    // A manual edit clears an outdated summary; never fall back to an older version's board.
    const edited = (await currentPendingPlan(db, owner, sticker.stickerId))!;
    await db.update(plans).set({ animationPreviewAssetId: null }).where(eq(plans.id, edited.id));
    await turn("Revise the current motion");
    expect(summaryIn(plannerVisuals[3])).toBeUndefined();
  } finally { await close(); }
}, 30_000);
