import { afterEach, expect, it } from "vitest";
import { and, eq, sql } from "drizzle-orm";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiChatContext, type AiImageInput, type AiAnimationContext, type AnimationDraftingSession, type AiLayoutContext, type LayoutDraftingSession } from "@/lib/ai/gateway";
import { configurationReviewSelections } from "@/lib/contracts/configuration";
import { resolveStickerConfiguration, StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { chatMessages, generationEvents, generationJobs, plans, stickerRevisions, users } from "@/lib/db/schema";
import { confirmPlan } from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { cancelGenerationWorkflow } from "@/lib/services/workflows";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { animatedStickerWithAcceptedBase, resetWorkflowTestState } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { latestRetryableGeneration } from "@/lib/services/generation-retry";

afterEach(resetWorkflowTestState);

it.each(["checkpoint", "legacy"])("resumes the expression step with %s history, saved poses and animation", async (historyKind) => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-pose" });
    let buildJobId = "";
    let stopped = false;
    const requests: AiImageInput[] = [];
    class Provider extends MockAiProvider {
      override async generateStickerImage(input: AiImageInput) {
        requests.push(input);
        if (input.sheet?.tiles && !stopped) {
          stopped = true;
          await cancelGenerationWorkflow(db, "owner-pose", buildJobId);
          throw new Error("Stopped during expression generation");
        }
        return super.generateStickerImage(input);
      }
      override async routeChatTurn(input: AiChatContext) {
        expect(input.instruction).toBe("Retry the expressions step");
        expect(input.retryableGeneration).toMatchObject({ kind: "compose", state: "cancelled" });
        const steps = input.retryableGeneration!.steps;
        expect(steps.find((step) => step.name.endsWith(" idle"))?.status).toBe("complete");
        expect(steps.find((step) => step.name.endsWith(" wave"))?.status).toBe("complete");
        const expressions = steps.find((step) => step.name.endsWith(" expressions"));
        expect(expressions?.status).toBe("failed");
        return { type: "retry_generation" as const, stepId: expressions!.id };
      }
    }
    setAiProviderForTests(new Provider());
    const sticker = await createSticker(db, "owner-pose", {
      title: "Cat", kind: "animated", prompt: "A round cat", referenceAssetIds: [], controllable: true,
    });
    const planning = await createChatTurn(db, "owner-pose", sticker.stickerId, {
      text: "A round cat", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planning.jobId)).workflowStatus).toBe("succeeded");
    const plan = await db.select().from(plans).where(eq(plans.stickerId, sticker.stickerId)).then(firstRow);
    const build = await confirmPlan(db, "owner-pose", sticker.stickerId, plan!.id);
    buildJobId = build.jobId;
    await stickerGenerationWorkflow(build.jobId);
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, build.jobId)).then(firstRow))?.state).toBe("cancelled");
    if (historyKind === "legacy") {
      await db.delete(generationEvents).where(and(eq(generationEvents.jobId, build.jobId),
        sql`${generationEvents.dataJson}->>'checkpoint' = 'plan_build'`));
    }
    const beforeRetry = requests.length;
    const retry = await createChatTurn(db, "owner-pose", sticker.stickerId, {
      text: "Retry the expressions step", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");
    expect(requests.length - beforeRetry).toBe(1);
    expect(requests.at(-1)?.sheet?.tiles).toBe(true);
    const retryRows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, retry.jobId));
    expect(retryRows.filter((row) => row.content.startsWith("compose-")).map((row) => row.content))
      .toEqual(["compose-sprite Character expressions"]);
    const retryEvents = await db.select().from(generationEvents).where(eq(generationEvents.jobId, retry.jobId)).orderBy(generationEvents.id);
    expect(retryEvents.find((event) => event.dataJson.stage === "composing_sprite")?.dataJson.completedUnits).toBe(2);
    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, retry.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    expect(document.kind).toBe("animated");
    expect(document.configuration?.controls).toEqual(plan!.planJson.configuration?.controls);
    expect(document.layers[0]).toMatchObject({ type: "sprite", clipId: "idle", expressionId: "neutral" });
    expect(resolveStickerConfiguration(document, { pose: "wave", mood: "happy" }).layers[0])
      .toMatchObject({ type: "sprite", clipId: "wave", expressionId: "happy" });
    expect(document.layers[0].type === "sprite" && document.layers[0].clips.every((clip) => clip.frames.length > 1)).toBe(true);
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, retry.messageId)).then(firstRow))?.status).toBe("complete");

    // Once this attempt succeeds, the earlier failure must not be offered again.
    const followup = await createChatTurn(db, "owner-pose", sticker.stickerId, {
      text: "Thanks", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    const nextJob = await db.select().from(generationJobs).where(eq(generationJobs.id, followup.jobId)).then(firstRow);
    expect(await latestRetryableGeneration(db, nextJob!)).toBeUndefined();
  } finally { await close(); }
}, 30_000);

it("replays the saved animation route and original target instead of routing Retry as a new image", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const { stickerId, baseRevisionId } = await animatedStickerWithAcceptedBase(db, "owner-motion");
    let routes = 0;
    let animations = 0;
    class Provider extends MockAiProvider {
      override async routeChatTurn(input: AiChatContext) {
        routes += 1;
        if (input.instruction === "Retry") return { type: "retry_generation" as const };
        return { type: "animate" as const, instruction: "Bounce the hero gently", targetLayerId: "hero" };
      }
      override async animateSticker(input: AiAnimationContext, session: AnimationDraftingSession) {
        animations += 1;
        expect(input.instruction).toBe("Bounce the hero gently");
        expect(input.targetLayerId).toBe("hero");
        if (animations === 1) throw new Error("Animation provider unavailable");
        return super.animateSticker(input, session);
      }
    }
    setAiProviderForTests(new Provider());
    const original = await createChatTurn(db, "owner-motion", stickerId, {
      text: "Please move it", intent: "chat", baseRevisionId, attachments: [], imagePlacement: "replace",
    });
    expect(await stickerGenerationWorkflow(original.jobId)).toEqual({ status: "failed" });
    const retry = await createChatTurn(db, "owner-motion", stickerId, {
      text: "Retry", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");
    expect(routes).toBe(2);
    expect(animations).toBe(2);
  } finally { await close(); }
});


it("continues an interrupted configuration review without replaying completed composing steps", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-review" });
    let buildJobId = "";
    let reviewAttempts = 0;
    let drawings = 0;
    class Provider extends MockAiProvider {
      override async generateStickerImage(input: AiImageInput) {
        drawings += 1;
        return super.generateStickerImage(input);
      }
      override async routeChatTurn() { return { type: "retry_generation" as const }; }
      override async refineStickerLayout(input: AiLayoutContext, session: LayoutDraftingSession) {
        reviewAttempts += 1;
        if (reviewAttempts === 1) {
          await session.viewPlanImage!();
          await session.renderSticker();
          await session.applyLayout({ placements: [{ layerId: "hero", x: 0.45, y: 0.5, scaleX: 0.8, scaleY: 0.8, rotationDegrees: 0 }] });
          await session.renderSticker();
          await session.renderSticker();
          await cancelGenerationWorkflow(db, "owner-review", buildJobId);
          throw new Error("Stopped after two review checks");
        }
        expect(input.document.layers[0].anchor.position.x).toBeCloseTo(0.45);
        expect(input.instruction).toContain("2 of");
        const total = configurationReviewSelections(input.document.configuration!).length;
        for (let index = 2; index < total; index += 1) await session.renderSticker();
        const finished = await session.finalizeLayout();
        return { revision: finished.revision, finalized: true };
      }
    }
    setAiProviderForTests(new Provider());
    const sticker = await createSticker(db, "owner-review", {
      title: "Pixel emoji", kind: "animated", prompt: "Pixel emoji", referenceAssetIds: [], controllable: true,
    });
    const planning = await createChatTurn(db, "owner-review", sticker.stickerId, {
      text: "Pixel emoji", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planning.jobId)).workflowStatus).toBe("succeeded");
    const plan = await db.select().from(plans).where(eq(plans.stickerId, sticker.stickerId)).then(firstRow);
    const build = await confirmPlan(db, "owner-review", sticker.stickerId, plan!.id);
    buildJobId = build.jobId;
    await stickerGenerationWorkflow(build.jobId);
    expect(reviewAttempts).toBe(1);
    const beforeRetry = drawings;
    const retry = await createChatTurn(db, "owner-review", sticker.stickerId, {
      text: "Continue the sticker", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");
    expect(drawings).toBe(beforeRetry);
    const rows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, retry.jobId));
    expect(rows.filter((row) => row.content.startsWith("compose-"))).toHaveLength(0);
    expect(rows.filter((row) => row.content.startsWith("view_sticker")).sort((a, b) => a.sequence - b.sequence)[0]?.content)
      .toBe("view_sticker #4");
    const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, retry.jobId)).orderBy(generationEvents.id);
    expect(events.filter((event) => event.dataJson.stage === "composing")).toHaveLength(0);
    expect(events.find((event) => event.dataJson.stage === "reviewing")?.dataJson.completedUnits).toBe(2);
    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, retry.jobId)).then(firstRow);
    expect(StickerDocumentSchema.parse(revision!.documentJson).layers[0].anchor.position.x).toBeCloseTo(0.45);
  } finally { await close(); }
}, 30_000);
