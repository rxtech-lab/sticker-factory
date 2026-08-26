import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { setAiProviderForTests, type AiProvider } from "@/lib/ai/gateway";
import { StickerDocumentSchema, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, generationEvents, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { derivedAssetId } from "@/lib/services/assets";
import { cancelPlan, confirmPlan } from "@/lib/services/plans";
import { acceptRevision, bindExports, createCandidateRevision, createChatTurn, createCleanupJob, createSticker, listChatMessages, retryFailedChatTurn } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { beginJobStep, executeAiJobStep, failJobStep, finalizeStickerPurgeStep, purgeStickerStep, sweepStickerObjectsStep } from "@/workflows/sticker-generation/steps";

/**
 * Base for a provider stub: every method fails loudly, so a test only spells out the calls its own
 * path makes and an unexpected one is a failure rather than a silent default.
 */
const unusedAiProvider: AiProvider = {
  generateStickerImage: () => { throw new Error("Unexpected generateStickerImage"); },
  planSticker: () => { throw new Error("Unexpected planSticker"); },
  generateConceptImage: () => { throw new Error("Unexpected generateConceptImage"); },
  animateSticker: () => { throw new Error("Unexpected animateSticker"); },
  routeChatTurn: () => { throw new Error("Unexpected routeChatTurn"); },
  showSticker: () => { throw new Error("Unexpected showSticker"); },
  reply: () => { throw new Error("Unexpected reply"); },
};

describe("durable sticker workflow", () => {
  afterEach(() => {
    setDatabaseForTests(undefined);
    setObjectStoreForTests(undefined);
    setAiProviderForTests(undefined);
  });

  it("completes base confirmation before streaming complete validated animation snapshots", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-a", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-a", { title: "Bounce", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Happy cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    const baseJob = await db.select().from(generationJobs).where(eq(generationJobs.id, baseTurn.jobId)).get();
    expect(baseJob?.state).toBe("succeeded");
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).get();
    expect(baseRevision?.candidateState).toBe("candidate");
    await acceptRevision(db, "owner-a", sticker.stickerId, baseRevision!.id);

    const animationTurn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Bounce and wiggle",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: baseRevision!.id,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animationTurn.jobId)).workflowStatus).toBe("succeeded");
    const snapshots = await db.select().from(generationEvents).where(eq(generationEvents.jobId, animationTurn.jobId));
    expect(snapshots.filter((event) => event.type === "document")).toHaveLength(3);
    expect(snapshots.at(-1)?.type).toBe("completed");

    const refinementTurn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Make the live candidate bounce a little faster",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: animationTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(refinementTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, refinementTurn.jobId)).get())?.parentRevisionId)
      .toBe(animationTurn.jobId);
    await acceptRevision(db, "owner-a", sticker.stickerId, animationTurn.jobId);
    await expect(createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Try to refine the superseded branch",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: refinementTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    })).rejects.toMatchObject({ code: "ANIMATION_BASE_NOT_ACCEPTED" });

    const animationRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animationTurn.jobId)).get();
    const pingPongDocument = StickerDocumentSchema.parse({ ...animationRevision!.documentJson, loop: "pingPong" });
    const pingPongRevisionId = await createCandidateRevision(db, {
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      sourceMessageId: animationTurn.messageId,
      document: pingPongDocument,
      parentRevisionId: animationTurn.jobId,
      masterAssetId: animationRevision!.masterAssetId ?? undefined,
      previewAssetId: animationRevision!.previewAssetId ?? undefined,
    });
    await acceptRevision(db, "owner-a", sticker.stickerId, pingPongRevisionId);
    const renditionIds = { gif: crypto.randomUUID(), mp4: crypto.randomUUID(), system: crypto.randomUUID() };
    await db.insert(assets).values([
      // A ping-ponged 2 s document is a 4 s motion cycle; every rendition then holds its last frame
      // for 0.6 s before repeating, so the encoded file runs 4.6 s over the same frame grid.
      { id: renditionIds.gif, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "gif", state: "ready", r2Key: objectKey("owner-a", renditionIds.gif, "image/gif"), mimeType: "image/gif", byteSize: 200_000, width: 1024, height: 1024, frameCount: 120, durationSeconds: 4.6, fps: 120 / 4.6, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.mp4, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "mp4", state: "ready", r2Key: objectKey("owner-a", renditionIds.mp4, "video/mp4"), mimeType: "video/mp4", byteSize: 300_000, width: 1024, height: 1024, frameCount: 120, durationSeconds: 4.6, fps: 120 / 4.6, sha256: "b".repeat(64), hasAlpha: false, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", renditionIds.system, "image/gif"), mimeType: "image/gif", byteSize: 400_000, width: 408, height: 408, frameCount: 60, durationSeconds: 4.6, fps: 60 / 4.6, sha256: "c".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    ]);
    const publishedRevisionId = crypto.randomUUID();
    const publishRequest = {
      revisionId: pingPongRevisionId,
      gifAssetId: renditionIds.gif,
      mp4AssetId: renditionIds.mp4,
      systemAssetId: renditionIds.system,
      mp4Background: { type: "linearGradient" as const, colors: ["#112233", "#445566"] as [string, string], angleDegrees: 30 },
    };
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...publishRequest,
      pngAssetId: animationRevision!.masterAssetId!,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "ANIMATED_EXPORT_MATRIX" });
    const published = await bindExports(db, "owner-a", sticker.stickerId, publishRequest, publishedRevisionId);
    expect((await bindExports(db, "owner-a", sticker.stickerId, publishRequest, publishedRevisionId)).revisionId).toBe(published.revisionId);
    const publishedRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).get();
    expect(StickerDocumentSchema.parse(publishedRevision!.documentJson).mp4Background.type).toBe("linearGradient");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get())?.activeRevisionId).toBe(publishedRevisionId);

    const retryTurn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Make it warmer",
      intent: "edit",
      baseRevisionId: publishedRevisionId,
      targetLayerId: "hero",
      attachments: [],
      imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "failed", completedAt: new Date() }).where(eq(generationJobs.id, retryTurn.jobId));
    await db.update(chatMessages).set({ status: "failed" }).where(eq(chatMessages.id, retryTurn.messageId));
    const retry = await retryFailedChatTurn(db, "owner-a", sticker.stickerId, retryTurn.messageId);
    await stickerGenerationWorkflow(retry.jobId);
    await expect(retryFailedChatTurn(db, "owner-a", sticker.stickerId, retryTurn.messageId))
      .rejects.toMatchObject({ code: "MESSAGE_NOT_RETRYABLE" });
    await close();
  }, 30_000);

  it("routes picker-free chat turns and shows sticker revisions as assistant attachments", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-chat", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-chat", {
      title: "Natural chat",
      kind: "static",
      prompt: "Happy cloud",
      referenceAssetIds: [],
    });
    const baseTurn = await createChatTurn(db, "owner-chat", sticker.stickerId, {
      text: "Happy cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-chat", sticker.stickerId, baseTurn.jobId);

    const editTurn = await createChatTurn(db, "owner-chat", sticker.stickerId, {
      text: "Make it blue",
      intent: "chat",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, editTurn.messageId)).get())?.kind).toBe("image_edit");
    const editReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId));
    expect(editReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["edit-sticker", "show-sticker"]);
    expect(editReply.filter((message) => message.role === "system").every((message) => message.status === "complete")).toBe(true);
    const streamedTools = (await db.select().from(generationEvents).where(eq(generationEvents.jobId, editTurn.jobId)))
      .map((event) => event.dataJson)
      .filter((data) => typeof data.toolName === "string")
      .map((data) => ({ name: data.toolName, status: data.toolStatus }));
    expect(streamedTools).toEqual([
      { name: "edit-sticker", status: "streaming" },
      { name: "edit-sticker", status: "complete" },
      { name: "show-sticker", status: "streaming" },
      { name: "show-sticker", status: "complete" },
    ]);
    expect(editReply.find((message) => message.role === "assistant")).toMatchObject({
      revisionId: editTurn.jobId,
      kind: "image_edit",
    });

    const showTurn = await createChatTurn(db, "owner-chat", sticker.stickerId, {
      text: "Show me the sticker",
      intent: "chat",
      baseRevisionId: editTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(showTurn.jobId)).workflowStatus).toBe("succeeded");
    const showReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, showTurn.jobId));
    expect(showReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["show-sticker"]);
    expect(showReply.find((message) => message.role === "assistant")).toMatchObject({
      revisionId: editTurn.jobId,
      kind: "image",
    });
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, showTurn.jobId)).get()).toBeUndefined();
    await close();
  }, 30_000);

  it("routes a new-element request to generate-image and adds a layer instead of replacing one", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-layer", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-layer", {
      title: "Layered",
      kind: "static",
      prompt: "Happy cloud",
      referenceAssetIds: [],
    });
    const baseTurn = await createChatTurn(db, "owner-layer", sticker.stickerId, {
      text: "Happy cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-layer", sticker.stickerId, baseTurn.jobId);
    const baseDocument = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).get())!.documentJson,
    );
    expect(baseDocument.layers).toHaveLength(1);

    const addTurn = await createChatTurn(db, "owner-layer", sticker.stickerId, {
      text: "Draw a rainbow next to it",
      intent: "chat",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(addTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, addTurn.messageId)).get()))
      .toMatchObject({ kind: "image_edit", imagePlacement: "add" });
    const addReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, addTurn.jobId));
    expect(addReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["generate-image", "show-sticker"]);

    // The point of the tool: the original layer survives and the new artwork lands beside it.
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, addTurn.jobId)).get())!.documentJson,
    );
    expect(document.layers).toHaveLength(2);
    expect(document.layers[0]).toMatchObject({ id: baseDocument.layers[0].id, assetId: baseTurn.jobId });
    expect(document.layers[1]).toMatchObject({ type: "image", name: "Generated layer", assetId: addTurn.jobId });
    const added = await db.select().from(assets).where(eq(assets.id, addTurn.jobId)).get();
    expect(added).toMatchObject({ kind: "master", state: "ready", hasAlpha: true });
    await close();
  }, 30_000);

  it("repairs a rejected animation inside the tool loop instead of re-planning it", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-repair", createdAt: new Date(), updatedAt: new Date() });

    const spec = (delay: number) => ({ type: "pulse" as const, delay, duration: 0.5, easing: "easeInOut" as const, minScale: 0.92, maxScale: 1.08, cycles: 3 });
    const entrance = { type: "popIn" as const, delay: 0, duration: 0.5, easing: "easeOut" as const, from: 0.6 };
    const rejections: string[] = [];

    const sticker = await createSticker(db, "owner-repair", { title: "Pop", kind: "animated", prompt: "Pop", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-repair", sticker.stickerId, {
      text: "Pop",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-repair", sticker.stickerId, baseTurn.jobId);

    // Only the animation turn is stubbed; the base image came from the ordinary mock above.
    setAiProviderForTests({
      ...unusedAiProvider,
      // The first attempt puts the entrance and the idle effect on the same channel at the same
      // instant — the mistake the real planner keeps making. The compiler's refusal comes back as
      // a tool error, and the repair moves the pulse out of the way and changes nothing else.
      async animateSticker(_input, session) {
        const attempt = (delay: number) => session.createAnimation([{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: [entrance, spec(delay)],
        } as StickerOperationV1]);
        try {
          await attempt(0);
        } catch (error) {
          rejections.push((error as Error).message);
        }
        const created = await attempt(0.5);
        const finalized = await session.finalizeAnimation(created.animationId);
        return { animationId: finalized.animationId, revision: finalized.revision, finalized: true };
      },
      async showSticker() { return "Here is the animation."; },
    });

    const animateTurn = await createChatTurn(db, "owner-repair", sticker.stickerId, {
      text: "Pop in then pulse",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animateTurn.jobId)).workflowStatus).toBe("succeeded");

    // The compiler's own words reached the caller, so the second attempt is a repair, not a rerun.
    expect(rejections).toHaveLength(1);
    expect(rejections[0]).toContain("scale channel");
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).get())!.documentJson,
    );
    expect(document.layers[0].animations.map((animation) => animation.delay)).toEqual([0, 0.5]);
    // The retry gets its own transcript row: reusing the label would leave the failed one showing.
    const rows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, animateTurn.jobId));
    const toolRows = rows.filter((message) => message.role === "system");
    expect(toolRows.map((message) => message.content))
      .toEqual(["animate-sticker", "create_animation", "create_animation #2", "finalize_animation", "show-sticker"]);
    expect(toolRows.find((message) => message.content === "create_animation")?.status).toBe("failed");
    expect(toolRows.find((message) => message.content === "create_animation #2")?.status).toBe("complete");
    await close();
  }, 30_000);

  /** An animated sticker with one accepted base revision, ready for an animate turn. */
  async function animatedStickerWithAcceptedBase(db: Awaited<ReturnType<typeof createTestDatabase>>["db"], ownerId: string) {
    await db.insert(users).values({ id: ownerId, createdAt: new Date(), updatedAt: new Date() });
    const sticker = await createSticker(db, ownerId, { title: "Loop", kind: "animated", prompt: "Loop", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, ownerId, sticker.stickerId, {
      text: "Loop",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, ownerId, sticker.stickerId, baseTurn.jobId);
    return { stickerId: sticker.stickerId, baseRevisionId: baseTurn.jobId };
  }

  const animateTurnOn = (db: Awaited<ReturnType<typeof createTestDatabase>>["db"], ownerId: string, stickerId: string, baseRevisionId: string) =>
    createChatTurn(db, ownerId, stickerId, {
      text: "Give it some motion",
      intent: "animate",
      baseRevisionId,
      attachments: [],
      imagePlacement: "replace",
    });

  it("applies an update to the base document rather than stacking it on the previous attempt", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const { stickerId, baseRevisionId } = await animatedStickerWithAcceptedBase(db, "owner-restate");

    setAiProviderForTests({
      ...unusedAiProvider,
      // The second call keeps the spin only because it re-sends it. An implementation that patched
      // the previous attempt instead would leave the discarded pulse behind and still pass a test
      // that only looked at the spin.
      async animateSticker(_input, session) {
        const created = await session.createAnimation([{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: [{ type: "pulse", delay: 0, duration: 0.6, easing: "easeInOut", minScale: 0.92, maxScale: 1.08, cycles: 3 }],
        } as StickerOperationV1]);
        const updated = await session.updateAnimation(created.animationId, [{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: [{ type: "spin", delay: 0, duration: 1, easing: "linear", turns: 1, direction: "cw" }],
        } as StickerOperationV1]);
        const finalized = await session.finalizeAnimation(updated.animationId);
        return { animationId: finalized.animationId, revision: finalized.revision, finalized: true };
      },
      async showSticker() { return "Here is the animation."; },
    });

    const turn = await animateTurnOn(db, "owner-restate", stickerId, baseRevisionId);
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).get())!.documentJson,
    );
    expect(document.layers[0].animations.map((animation) => animation.type)).toEqual(["spin"]);
    await close();
  }, 30_000);

  it("ships whatever landed when the loop stops without finalizing", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const { stickerId, baseRevisionId } = await animatedStickerWithAcceptedBase(db, "owner-capped");

    setAiProviderForTests({
      ...unusedAiProvider,
      // What a model that keeps polishing until it trips the step cap looks like from here.
      async animateSticker(_input, session) {
        await session.createAnimation([{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: [{ type: "float", delay: 0, duration: 1.5, easing: "easeInOut", amplitude: 0.05, cycles: 2 }],
        } as StickerOperationV1]);
        return undefined;
      },
      async showSticker() { return "Here is the animation."; },
    });

    const turn = await animateTurnOn(db, "owner-capped", stickerId, baseRevisionId);
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).get())!.documentJson,
    );
    expect(document.layers[0].animations.map((animation) => animation.type)).toEqual(["float"]);
    await close();
  }, 30_000);

  it("fails the turn when the loop lands no motion at all", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const { stickerId, baseRevisionId } = await animatedStickerWithAcceptedBase(db, "owner-empty");

    setAiProviderForTests({
      ...unusedAiProvider,
      async animateSticker() { return undefined; },
    });

    const turn = await animateTurnOn(db, "owner-empty", stickerId, baseRevisionId);
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).not.toBe("succeeded");
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).get())?.state).toBe("failed");
    // Publishing the untouched base back as a candidate would ask the user to keep a sticker that
    // never changed, so nothing is written at all.
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).get()).toBeUndefined();
    await close();
  }, 30_000);

  it("stops the loop instead of inviting a repair when the turn is cancelled mid-draft", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const { stickerId, baseRevisionId } = await animatedStickerWithAcceptedBase(db, "owner-cancel");
    let secondCallFailedWith: string | undefined;

    setAiProviderForTests({
      ...unusedAiProvider,
      async animateSticker(_input, session) {
        const wiggle = [{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: [{ type: "wiggle", delay: 0, duration: 1, easing: "easeInOut", amplitudeDegrees: 6, cycles: 3 }],
        } as StickerOperationV1];
        const created = await session.createAnimation(wiggle);
        // Stands in for the user hitting Stop: the row the step keeps checking stops saying running.
        await db.update(generationJobs).set({ state: "cancelled" })
          .where(eq(generationJobs.state, "running"));
        // A cancelled turn is not something the model can fix, so the session must refuse rather
        // than hand back advice the loop would spend its remaining steps acting on.
        await session.updateAnimation(created.animationId, wiggle).catch((error: Error) => {
          secondCallFailedWith = error.name;
        });
        return undefined;
      },
    });

    const turn = await animateTurnOn(db, "owner-cancel", stickerId, baseRevisionId);
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).not.toBe("succeeded");
    expect(secondCallFailedWith).toBe("AnimationTurnAbort");
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).get()).toBeUndefined();
    await close();
  }, 30_000);

  it("animates the first generation before anything has been accepted", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-first", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-first", { title: "Wave", kind: "animated", prompt: "Wave", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-first", sticker.stickerId, {
      text: "A waving hand",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get())?.activeRevisionId).toBeNull();

    // Nothing has ever been accepted, so there is no chain to walk: this candidate is the project.
    const animateTurn = await animateTurnOn(db, "owner-first", sticker.stickerId, baseTurn.jobId);
    expect((await stickerGenerationWorkflow(animateTurn.jobId)).workflowStatus).toBe("succeeded");
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).get())
      .toMatchObject({ parentRevisionId: baseTurn.jobId, candidateState: "candidate" });
    await close();
  }, 30_000);

  it("animates a candidate the user has not kept yet", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-unkept", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-unkept", { title: "OMG", kind: "animated", prompt: "OMG", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-unkept", sticker.stickerId, {
      text: "OMG",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-unkept", sticker.stickerId, baseTurn.jobId);

    // A drawn layer the user has not decided on yet, which is what they will be looking at.
    const addTurn = await createChatTurn(db, "owner-unkept", sticker.stickerId, {
      text: "Draw a rainbow next to it",
      intent: "chat",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(addTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, addTurn.jobId)).get())?.candidateState)
      .toBe("candidate");

    const animateTurn = await createChatTurn(db, "owner-unkept", sticker.stickerId, {
      text: "Animate the new artwork",
      intent: "chat",
      baseRevisionId: addTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animateTurn.jobId)).workflowStatus).toBe("succeeded");

    const turnRows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, animateTurn.jobId));
    expect(turnRows.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["animate-sticker", "create_animation", "update_animation", "finalize_animation", "show-sticker"]);
    expect(turnRows.find((message) => message.role === "assistant"))
      .toMatchObject({ kind: "animation", revisionId: animateTurn.jobId });
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, animateTurn.messageId)).get())?.kind)
      .toBe("animation");

    // The motion branched off the candidate, and deciding about it is still the user's to make.
    const animated = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).get();
    expect(animated).toMatchObject({ parentRevisionId: addTurn.jobId, candidateState: "candidate" });
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get())?.activeRevisionId)
      .toBe(baseTurn.jobId);
    await close();
  }, 30_000);

  it("plans instead of failing when an edit lands on a document the image tools cannot touch", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-text", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-text", { title: "OMG", kind: "animated", prompt: "OMG", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-text", sticker.stickerId, {
      text: "OMG",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).get();

    // What a confirmed plan leaves behind: lettering and effects the app draws, and no artwork at
    // all for the image model to work from.
    const textOnly = StickerDocumentSchema.parse({
      ...baseRevision!.documentJson,
      layers: [
        // v2 layers: the base document is v2, and the upcast keys on `version`, so a document
        // cannot be half one shape and half the other.
        { id: "omg_text", name: "OMG", type: "text", text: "OMG", font: "rounded", weight: "bold", paint: { type: "solid", color: "#FF0055" } },
        { id: "confetti", name: "Confetti", type: "particle", preset: "confetti", count: 24, paint: { type: "solid", color: "#FFCC00" }, seed: 7 },
      ],
    });
    const textOnlyRevisionId = await createCandidateRevision(db, {
      ownerId: "owner-text",
      stickerId: sticker.stickerId,
      sourceMessageId: baseTurn.messageId,
      document: textOnly,
      parentRevisionId: baseTurn.jobId,
      masterAssetId: baseRevision!.masterAssetId ?? undefined,
      previewAssetId: baseRevision!.previewAssetId ?? undefined,
    });
    await acceptRevision(db, "owner-text", sticker.stickerId, textOnlyRevisionId);

    const editTurn = await createChatTurn(db, "owner-text", sticker.stickerId, {
      text: "Make the OMG lettering cartoon-like artwork",
      intent: "chat",
      baseRevisionId: textOnlyRevisionId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");

    // Redrawing app-drawn lettering is a redesign, so the turn proposes a plan and destroys nothing.
    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId)))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(toolRows[0]).toBe("plan-sticker");
    expect(await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId))).toHaveLength(1);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, editTurn.jobId)).get()).toBeUndefined();
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get())?.activeRevisionId)
      .toBe(textOnlyRevisionId);
    await close();
  }, 30_000);

  it("retains the deletion tombstone until the delayed object sweep finishes", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    await db.insert(users).values({ id: "owner-b", createdAt: new Date(), updatedAt: new Date() });
    const referenceId = crypto.randomUUID();
    const referenceKey = objectKey("owner-b", referenceId, "image/png");
    await db.insert(assets).values({ id: referenceId, ownerId: "owner-b", kind: "reference", state: "ready", r2Key: referenceKey, mimeType: "image/png", byteSize: 3, createdAt: new Date(), readyAt: new Date() });
    await store.put(referenceKey, { bytes: new Uint8Array([1, 2, 3]), contentType: "image/png" });
    const sticker = await createSticker(db, "owner-b", { title: "Delete", kind: "static", prompt: "Delete", referenceAssetIds: [referenceId] });
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const turn = await createChatTurn(db, "owner-b", sticker.stickerId, { text: "Delete", intent: "generate", attachments: [{ assetId: referenceId, kind: "reference" }], imagePlacement: "replace" });
    await stickerGenerationWorkflow(turn.jobId);
    await acceptRevision(db, "owner-b", sticker.stickerId, turn.jobId);
    const generatedAsset = await db.select().from(assets).where(eq(assets.id, turn.jobId)).get();
    const key = generatedAsset!.r2Key;
    expect(store.objects.has(key)).toBe(true);
    const cleanupJobId = await createCleanupJob(db, "owner-b", sticker.stickerId);
    await beginJobStep(cleanupJobId);
    const keys = await purgeStickerStep(cleanupJobId);
    expect(store.objects.has(key)).toBe(false);
    expect(await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get()).toBeTruthy();
    await failJobStep(cleanupJobId, "simulated R2 outage after first sweep");
    const retriedCleanupJobId = await createCleanupJob(db, "owner-b", sticker.stickerId);
    expect(retriedCleanupJobId).toBe(cleanupJobId);
    await beginJobStep(retriedCleanupJobId);
    await store.put(key, { bytes: new Uint8Array([4]), contentType: "image/png" });
    const retriedKeys = await purgeStickerStep(retriedCleanupJobId);
    await store.put(key, { bytes: new Uint8Array([5]), contentType: "image/png" });
    await sweepStickerObjectsStep([...new Set([...keys, ...retriedKeys])]);
    expect(store.objects.has(key)).toBe(false);
    await finalizeStickerPurgeStep(cleanupJobId);
    expect(await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).get()).toBeUndefined();
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(0);
    expect(await db.select().from(chatMessages)).toHaveLength(0);
    expect(await db.select().from(chatAttachments)).toHaveLength(0);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(0);
    await close();
  });
  it("drafts a plan, generates nothing until it is confirmed, then builds it with compiled motion", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-c", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-c", { title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [] });
    const planTurn = await createChatTurn(db, "owner-c", sticker.stickerId, {
      text: "Make HI appear letter by letter like a typewriter",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");

    // The planning turn is cheap: a draft and nothing else.
    const proposed = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(proposed).toHaveLength(1);
    expect(proposed[0].state).toBe("finalized");
    // create_plan then update_plan, so the draft was revised before it was frozen.
    expect(proposed[0].revision).toBe(2);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(0);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(0);

    const planMessage = (await listChatMessages(db, "owner-c", sticker.stickerId)).data
      .find((message) => message.kind === "plan");
    expect(planMessage?.plan?.state).toBe("finalized");
    expect(planMessage?.plan?.actionable).toBe(true);
    expect(planMessage?.plan?.plan.layers.length).toBeGreaterThanOrEqual(2);

    // Each plan tool call left its own row, so the client can render the drafting sequence live.
    const planToolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, planTurn.jobId)))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(planToolRows).toEqual(expect.arrayContaining([
      "plan-sticker", "create_plan", "update_plan #1", "show_plan", "finalize_plan",
    ]));

    // The completed event carries the assistant message so the client need not refetch.
    const planEvents = await db.select().from(generationEvents).where(eq(generationEvents.jobId, planTurn.jobId));
    const completed = planEvents.find((event) => event.type === "completed");
    expect((completed?.dataJson as { assistantMessage?: { content?: string } }).assistantMessage?.content)
      .toBe(planMessage?.content);

    const partCount = proposed[0].planJson.layers.length;
    const confirmed = await confirmPlan(db, "owner-c", sticker.stickerId, proposed[0].id);
    await expect(confirmPlan(db, "owner-c", sticker.stickerId, proposed[0].id))
      .rejects.toMatchObject({ code: "PLAN_ALREADY_CONFIRMED" });
    expect((await stickerGenerationWorkflow(confirmed.jobId)).workflowStatus).toBe("succeeded");

    const composedAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(composedAssets).toHaveLength(partCount);
    expect(composedAssets.map((asset) => asset.id).sort())
      .toEqual(Array.from({ length: partCount }, (_, index) => derivedAssetId(confirmed.jobId, index)).sort());

    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, confirmed.jobId)).get();
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    expect(document.layers).toHaveLength(partCount);
    for (const layer of document.layers) {
      // Layout still rides on the anchor, which compiles to a single t=0 position keyframe.
      expect(layer.animation.position).toHaveLength(1);
      expect(layer.animation.position[0].timeSeconds).toBe(0);
    }

    // Motion came from the plan's declarative specs, compiled deterministically rather than by a
    // second AI pass, and each layer starts later than the one before it.
    const popIns = document.layers.map((layer) => layer.animations.find((spec) => spec.type === "popIn"));
    expect(popIns.every(Boolean)).toBe(true);
    const delays = popIns.map((spec) => spec!.delay);
    expect(delays).toEqual([...delays].sort((a, b) => a - b));
    expect(delays[1]).toBeGreaterThan(delays[0]);
    for (const layer of document.layers) {
      const [spec] = layer.animations;
      // Rounded because the compiler rounds its emitted times; raw JS addition would leave
      // 0.2 + 0.4 as 0.6000000000000001 and the two would never match.
      const round = (value: number) => Math.round(value * 10_000) / 10_000;
      expect(layer.animation.opacity.map((frame) => frame.timeSeconds))
        .toEqual([round(spec.delay), round(spec.delay + spec.duration)]);
    }

    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, confirmed.jobId)))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(toolRows).toContain("build-plan");
    expect(toolRows.filter((name) => name.startsWith("compose-part:"))).toHaveLength(partCount);

    // A step retry must not mint a second set of assets or a second revision: that is what the
    // (jobId, index) derived asset ids and the deterministic revision id are for.
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, confirmed.jobId));
    const replay = await executeAiJobStep(confirmed.jobId);
    expect(replay.revisionId).toBe(confirmed.jobId);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(partCount);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(1);

    await close();
  });

  it("refuses to act on a plan that is no longer actionable", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-d", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-d", { title: "HI", kind: "static", prompt: "HI", referenceAssetIds: [] });
    const first = await createChatTurn(db, "owner-d", sticker.stickerId, {
      text: "Compose the word HI from separate letters",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(first.jobId);
    const second = await createChatTurn(db, "owner-d", sticker.stickerId, {
      text: "Actually compose it one at a time with more spacing",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(second.jobId);

    // A second planning turn starts a fresh plan and supersedes the previous one, so only one plan
    // is ever actionable, and the new row links back to what it replaced.
    const plans = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(plans).toHaveLength(2);
    expect(plans.filter((plan) => plan.state === "finalized")).toHaveLength(1);
    const superseded = plans.find((plan) => plan.state === "superseded")!;
    const live = plans.find((plan) => plan.state === "finalized")!;
    expect(live.supersedesId).toBe(superseded.id);
    await expect(confirmPlan(db, "owner-d", sticker.stickerId, superseded.id))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });

    // A dismissal records why, so the next planning turn can be told what was turned down.
    expect(await cancelPlan(db, "owner-d", sticker.stickerId, live.id, "Too cramped"))
      .toMatchObject({ state: "cancelled" });
    expect((await db.select().from(planRows).where(eq(planRows.id, live.id)).get())?.decisionReason)
      .toBe("Too cramped");
    await expect(confirmPlan(db, "owner-d", sticker.stickerId, live.id))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });
    await close();
  });
  it("lets project creation itself propose a composition instead of one flat image", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-e", createdAt: new Date(), updatedAt: new Date() });

    // The creation endpoint uses intent "generate", which never reaches the chat router. A first
    // prompt asking for a per-element effect must still be able to become a plan, because a
    // single flat image can never be keyframed into a typewriter reveal afterwards.
    const sticker = await createSticker(db, "owner-e", {
      title: "HI", kind: "animated", prompt: "Typewriter effect typing the word Hi", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-e", sticker.stickerId, {
      text: "Typewriter effect typing the word Hi",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .toHaveLength(1);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(0);
    await close();
  });

  it("still generates a single image when creation does not need separate parts", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-f", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-f", {
      title: "Cloud", kind: "animated", prompt: "A happy cloud", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-f", sticker.stickerId, {
      text: "A happy cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .toHaveLength(0);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).get()).toBeTruthy();
    await close();
  });
});
