import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiPlanContext, type PlanDraftingSession } from "@/lib/ai/gateway";
import { setDatabaseForTests } from "@/lib/db/client";
import { PlanV1Schema, type PlanV1 } from "@/lib/contracts/plan";
import { plans, users } from "@/lib/db/schema";
import { currentPendingPlan } from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

afterEach(resetWorkflowTestState);

/**
 * The draft's reference image is what the user approves, and it is the most expensive thing a
 * planning turn buys. It is keyed on the prompt that draws it, so the agent revising the layout
 * around it — which is most of what `update_plan` does — must not send the same picture back to the
 * image model under a new revision number.
 */
it("draws the draft's reference once across revisions that do not change it, and again when they do", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "concept-cache-owner" });
    const prompts: string[] = [];

    const draft = (conceptPrompt: string, y: number): PlanV1 => PlanV1Schema.parse({
      version: 1,
      title: "Planned sticker",
      summary: "Here is a plan with one layer. Confirm to build it.",
      kind: "animated",
      conceptPrompt,
      timing: { durationSeconds: 2, fps: 30, loop: "loop" },
      layers: [{
        layerId: "part_0",
        name: "A",
        source: { kind: "generate", prompt: "The letter A as a bold sticker letter on a transparent background." },
        x: 0.5,
        y,
        scaleX: 0.6,
        scaleY: 0.6,
      }],
    });

    class Provider extends MockAiProvider {
      override async generateConceptImage(input: Parameters<MockAiProvider["generateConceptImage"]>[0]) {
        if (!input.purpose) prompts.push(input.prompt);
        return super.generateConceptImage(input);
      }
      /** Shows a draft, nudges the layout under the same reference, then changes the reference. */
      override async planSticker(_input: AiPlanContext, session: PlanDraftingSession) {
        const created = await session.createPlan(draft("A bold letter A in one coherent style.", 0.5));
        await session.showPlan(created.planId);
        await session.updatePlan(created.planId, draft("A bold letter A in one coherent style.", 0.4));
        await session.showPlan(created.planId);
        await session.updatePlan(created.planId, draft("A bold letter A in a soft pastel style.", 0.4));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      }
    }
    setAiProviderForTests(new Provider());

    const sticker = await createSticker(db, "concept-cache-owner", {
      title: "A", kind: "animated", prompt: "A", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "concept-cache-owner", sticker.stickerId, {
      text: "A", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    // Three renders, two distinct references: the moved layer reused the picture it was already
    // holding, and only the restyled prompt paid for a second one.
    expect(prompts).toEqual([
      "A bold letter A in one coherent style.",
      "A bold letter A in a soft pastel style.",
    ]);
    const plan = (await currentPendingPlan(db, "concept-cache-owner", sticker.stickerId))!;
    expect(plan.state).toBe("finalized");
    expect(plan.conceptAssetId).toBeTruthy();
    // The card points at the reference drawn for the plan as it stands, not the one it started on.
    const attached = await db.select().from(plans).where(eq(plans.id, plan.id));
    expect(attached[0]?.conceptAssetId).toBe(plan.conceptAssetId);
  } finally { await close(); }
}, 30_000);
