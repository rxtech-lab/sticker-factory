import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider, setAiProviderForTests, type AiProvider, type AiTitleContext } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { StickerDocumentSchema, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { cropPngToSubject } from "@/lib/images/subject-bounds";
import { layoutDiagnostics } from "@/lib/layout/composition";
import { placementFromSubject } from "@/lib/layout/placement";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, generationEvents, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { derivedAssetId } from "@/lib/services/assets";
import { cancelPlan, confirmPlan } from "@/lib/services/plans";
import { acceptRevision, bindExports, createCandidateRevision, createChatTurn, createCleanupJob, createSticker, listChatMessages, retryFailedChatTurn } from "@/lib/services/stickers";
import { MemoryObjectStore, normalizeTransparentPng, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { beginJobStep, executeAiJobStep, failJobStep, finalizeStickerPurgeStep, purgeStickerStep, sweepStickerObjectsStep } from "@/workflows/sticker-generation/steps";

/**
 * Base for a provider stub: every method fails loudly, so a test only spells out the calls its own
 * path makes and an unexpected one is a failure rather than a silent default.
 */
const unusedAiProvider: AiProvider = {
  // Reference selection is a background orchestration step on every image path. Focused tests can
  // override it to inspect or narrow candidates; other stubs preserve the legacy all-reference path.
  selectImageReferences: async (input) => input.candidates.map((_, index) => index),
  generateStickerImage: () => { throw new Error("Unexpected generateStickerImage"); },
  planSticker: () => { throw new Error("Unexpected planSticker"); },
  generateConceptImage: () => { throw new Error("Unexpected generateConceptImage"); },
  generateStickerVideo: () => { throw new Error("Unexpected generateStickerVideo"); },
  refineStickerLayout: () => { throw new Error("Unexpected refineStickerLayout"); },
  animateSticker: () => { throw new Error("Unexpected animateSticker"); },
  editSticker: () => { throw new Error("Unexpected editSticker"); },
  routeChatTurn: () => { throw new Error("Unexpected routeChatTurn"); },
  showSticker: () => { throw new Error("Unexpected showSticker"); },
  reply: () => { throw new Error("Unexpected reply"); },
  // The exception to the rule above: every successful turn ends by naming the sticker, so a stub
  // that threw here would only prove the naming step swallows its errors. Keeping the current name
  // is a real provider answer, and it leaves each test's own title assertions alone.
  summarizeStickerTitle: async ({ currentTitle }) => currentTitle,
};

describe("durable sticker workflow", () => {
  afterEach(() => {
    setDatabaseForTests(undefined);
    setObjectStoreForTests(undefined);
    setAiProviderForTests(undefined);
  });

  /**
   * Draws an animated project's first revision as one flat `hero` layer.
   *
   * An animated project that has never been planned is planned rather than drawn, so this is the
   * whole of the route a user has to a single-image base: the first prompt drafts a plan, they turn
   * it down, and the next prompt draws. The animation tests below want that base — a document with
   * one layer to keyframe — not the composition a confirmed plan would have built.
   */
  async function drawnAnimatedBase(
    db: Awaited<ReturnType<typeof createTestDatabase>>["db"],
    ownerId: string,
    stickerId: string,
    text: string,
  ) {
    const planTurn = await createChatTurn(db, ownerId, stickerId, {
      text, intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");
    const [plan] = await db.select().from(planRows).where(eq(planRows.stickerId, stickerId));
    // No reason given, so the plan is simply dropped rather than queueing a re-planning turn.
    await cancelPlan(db, ownerId, stickerId, plan.id);
    return createChatTurn(db, ownerId, stickerId, {
      text, intent: "generate", attachments: [], imagePlacement: "replace",
    });
  }

  it("completes base confirmation before streaming complete validated animation snapshots", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-a", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-a", { title: "Bounce", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-a", sticker.stickerId, "Happy cloud");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    const baseJob = await db.select().from(generationJobs).where(eq(generationJobs.id, baseTurn.jobId)).then(firstRow);
    expect(baseJob?.state).toBe("succeeded");
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);
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
    // One per landing — create, update, single-layer edit — and one for the revision they became.
    expect(snapshots.filter((event) => event.type === "document")).toHaveLength(4);
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
    expect((await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, refinementTurn.jobId)).then(firstRow))?.parentRevisionId)
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

    const animationRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animationTurn.jobId)).then(firstRow);
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
    const renditionIds = { apng: crypto.randomUUID(), mp4: crypto.randomUUID(), system: crypto.randomUUID() };
    await db.insert(assets).values([
      // A ping-ponged 2 s document is a 4 s motion cycle; every rendition then holds its last frame
      // for 0.6 s before repeating, so the encoded file runs 4.6 s. GIF and the system rendition
      // hold by giving that frame a longer delay, over the same 4 s grid; the MP4 has no per-frame
      // delay to lengthen, so it holds by repeating the frame 18 more times.
      { id: renditionIds.apng, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "apng", state: "ready", r2Key: objectKey("owner-a", renditionIds.apng, "image/png"), mimeType: "image/png", byteSize: 200_000, width: 1024, height: 1024, frameCount: 120, durationSeconds: 4.6, fps: 120 / 4.6, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.mp4, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "mp4", state: "ready", r2Key: objectKey("owner-a", renditionIds.mp4, "video/mp4"), mimeType: "video/mp4", byteSize: 300_000, width: 1024, height: 1024, frameCount: 138, durationSeconds: 4.6, fps: 138 / 4.6, sha256: "b".repeat(64), hasAlpha: false, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", renditionIds.system, "image/gif"), mimeType: "image/gif", byteSize: 400_000, width: 408, height: 408, frameCount: 60, durationSeconds: 4.6, fps: 60 / 4.6, sha256: "c".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    ]);
    const publishedRevisionId = crypto.randomUUID();
    const publishRequest = {
      revisionId: pingPongRevisionId,
      apngAssetId: renditionIds.apng,
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
    const publishedRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).then(firstRow);
    expect(StickerDocumentSchema.parse(publishedRevision!.documentJson).mp4Background.type).toBe("linearGradient");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.activeRevisionId).toBe(publishedRevisionId);

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

    // Some animations cannot be squeezed under Apple's 500 KB ceiling at any size or frame rate the
    // client's ladder reaches. Those publish their poster frame rather than failing to export, which
    // the client has to say outright — a single-frame system rendition is otherwise indistinguishable
    // from a client that uploaded the wrong file.
    const stillSystemId = crypto.randomUUID();
    await db.insert(assets).values([
      { id: stillSystemId, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", stillSystemId, "image/png"), mimeType: "image/png", byteSize: 40_000, width: 300, height: 300, frameCount: 1, durationSeconds: 0, fps: 0, sha256: "d".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    ]);
    const stillRequest = { ...publishRequest, revisionId: publishedRevisionId, systemAssetId: stillSystemId };
    await expect(bindExports(db, "owner-a", sticker.stickerId, stillRequest, crypto.randomUUID()))
      .rejects.toMatchObject({ code: "ANIMATED_SYSTEM_RENDITION_REQUIRED" });
    // The claim is checked against the file: an animated rendition may not be passed off as the
    // fallback, which is what stops the flag from becoming a way around the timing rules.
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...stillRequest, systemAssetId: renditionIds.system, systemRenditionKind: "still" as const,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "INVALID_STILL_SYSTEM_RENDITION" });
    const stillPublishedId = crypto.randomUUID();
    await bindExports(db, "owner-a", sticker.stickerId, { ...stillRequest, systemRenditionKind: "still" as const }, stillPublishedId);
    expect((await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, stillPublishedId)).then(firstRow))?.systemAssetId)
      .toBe(stillSystemId);
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
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, editTurn.messageId)).then(firstRow))?.kind).toBe("image_edit");
    const editReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId)).orderBy(chatMessages.sequence);
    expect(editReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["edit-sticker", "edit_image_layer", "finalize_edit", "show-sticker"]);
    expect(editReply.filter((message) => message.role === "system").every((message) => message.status === "complete")).toBe(true);
    const streamedTools = (await db.select().from(generationEvents).where(eq(generationEvents.jobId, editTurn.jobId)))
      .map((event) => event.dataJson)
      .filter((data) => typeof data.toolName === "string")
      .map((data) => ({ name: data.toolName, status: data.toolStatus }));
    expect(streamedTools).toEqual([
      { name: "edit-sticker", status: "streaming" },
      { name: "edit_image_layer", status: "streaming" },
      { name: "edit_image_layer", status: "complete" },
      { name: "finalize_edit", status: "streaming" },
      { name: "finalize_edit", status: "complete" },
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
    const showReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, showTurn.jobId)).orderBy(chatMessages.sequence);
    expect(showReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["show-sticker"]);
    expect(showReply.find((message) => message.role === "assistant")).toMatchObject({
      revisionId: editTurn.jobId,
      kind: "image",
    });
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, showTurn.jobId)).then(firstRow)).toBeUndefined();
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
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow))!.documentJson,
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
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, addTurn.messageId)).then(firstRow)))
      .toMatchObject({ kind: "image_edit", imagePlacement: "add" });
    const addReply = await db.select().from(chatMessages).where(eq(chatMessages.jobId, addTurn.jobId)).orderBy(chatMessages.sequence);
    expect(addReply.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["generate-image", "show-sticker"]);

    // The point of the tool: the original layer survives and the new artwork lands beside it.
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, addTurn.jobId)).then(firstRow))!.documentJson,
    );
    expect(document.layers).toHaveLength(2);
    expect(document.layers[0]).toMatchObject({ id: baseDocument.layers[0].id, assetId: baseTurn.jobId });
    expect(document.layers[1]).toMatchObject({ type: "image", name: "Generated layer", assetId: addTurn.jobId });
    // Beside it, not on top of it: the new layer is smaller than the hero, on canvas, and does not
    // sit dead centre where a full-size default would have covered the original.
    const added_layer = document.layers[1];
    expect(added_layer.anchor.scale.x).toBeLessThan(1);
    expect(added_layer.anchor.scale.x).toBe(added_layer.anchor.scale.y);
    expect(added_layer.anchor.position).not.toEqual({ x: 0.5, y: 0.5 });
    expect(layoutDiagnostics(document).offCanvasLayerIds).toEqual([]);
    const added = await db.select().from(assets).where(eq(assets.id, addTurn.jobId)).then(firstRow);
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
    const baseTurn = await drawnAnimatedBase(db, "owner-repair", sticker.stickerId, "Pop");
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
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).then(firstRow))!.documentJson,
    );
    expect(document.layers[0].animations.map((animation) => animation.delay)).toEqual([0, 0.5]);
    // The retry gets its own transcript row: reusing the label would leave the failed one showing.
    const rows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, animateTurn.jobId)).orderBy(chatMessages.sequence);
    const toolRows = rows.filter((message) => message.role === "system");
    expect(toolRows.map((message) => message.content))
      .toEqual(["animate-sticker", "create_animation", "create_animation #2", "finalize_animation", "show-sticker"]);
    expect(toolRows.find((message) => message.content === "create_animation")?.status).toBe("failed");
    expect(toolRows.find((message) => message.content === "create_animation #2")?.status).toBe("complete");
    const transcript = await listChatMessages(db, "owner-repair", sticker.stickerId);
    expect(transcript.data.find((message) => message.content === "create_animation")?.toolDetails)
      .toBe(rejections[0]);
    expect(transcript.data.find((message) => message.content === "create_animation #2")?.toolDetails)
      .toContain('"animationId"');
    const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, animateTurn.jobId));
    expect(events.find((event) => event.dataJson.toolStatus === "failed")?.dataJson.toolDetails)
      .toBe(rejections[0]);

    await close();
  }, 30_000);

  /** An animated sticker with one accepted base revision, ready for an animate turn. */
  async function animatedStickerWithAcceptedBase(db: Awaited<ReturnType<typeof createTestDatabase>>["db"], ownerId: string) {
    await db.insert(users).values({ id: ownerId, createdAt: new Date(), updatedAt: new Date() });
    const sticker = await createSticker(db, ownerId, { title: "Loop", kind: "animated", prompt: "Loop", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, ownerId, sticker.stickerId, "Loop");
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
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).then(firstRow))!.documentJson,
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
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).then(firstRow))!.documentJson,
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
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).then(firstRow))?.state).toBe("failed");
    // Publishing the untouched base back as a candidate would ask the user to keep a sticker that
    // never changed, so nothing is written at all.
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).then(firstRow)).toBeUndefined();
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
    expect(secondCallFailedWith).toBe("TurnAbort");
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).then(firstRow)).toBeUndefined();
    await close();
  }, 30_000);

  it("changes one layer's motion through edit_layer_animation and leaves the rest standing", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-one-layer", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-one-layer", { title: "OMG", kind: "animated", prompt: "OMG", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-one-layer", sticker.stickerId, "OMG");
    await stickerGenerationWorkflow(baseTurn.jobId);
    const drawn = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);

    // Two layers, so "leaves the rest standing" is something the document can actually show.
    const twoLayers = StickerDocumentSchema.parse({
      ...drawn!.documentJson,
      layers: [
        ...StickerDocumentSchema.parse(drawn!.documentJson).layers,
        { id: "omg_text", name: "OMG", type: "text", text: "OMG", font: "rounded", weight: "bold", paint: { type: "solid", color: "#FF0055" } },
      ],
    });
    const baseRevisionId = await createCandidateRevision(db, {
      ownerId: "owner-one-layer",
      stickerId: sticker.stickerId,
      sourceMessageId: baseTurn.messageId,
      document: twoLayers,
      parentRevisionId: baseTurn.jobId,
      masterAssetId: drawn!.masterAssetId ?? undefined,
      previewAssetId: drawn!.previewAssetId ?? undefined,
    });
    await acceptRevision(db, "owner-one-layer", sticker.stickerId, baseRevisionId);

    const scaleOn = (layerId: string, peak: number): StickerOperationV1 => ({
      op: "setScaleKeyframes",
      layerId,
      keyframes: [
        { timeSeconds: 0, x: 1, y: 1, easing: "easeOut" },
        { timeSeconds: 1, x: peak, y: peak, easing: "easeInOut" },
      ],
    });
    let refusedCrossLayerEdit: string | undefined;

    setAiProviderForTests({
      ...unusedAiProvider,
      async animateSticker(_input, session) {
        const created = await session.createAnimation([scaleOn("hero", 1.1), scaleOn("omg_text", 1.4)]);
        // Aiming at another layer from inside a single-layer edit is the model's own mistake, so it
        // comes back as text it can act on rather than quietly landing.
        await session.editLayerAnimation(created.animationId, "omg_text", [scaleOn("hero", 2)])
          .catch((error: Error) => { refusedCrossLayerEdit = error.message; });
        // Only the text layer is restated. The hero's scale is never sent again, and the point of
        // the test is that it survives anyway.
        const edited = await session.editLayerAnimation(created.animationId, "omg_text", [{
          op: "setRotationKeyframes",
          layerId: "omg_text",
          keyframes: [
            { timeSeconds: 0, degrees: -8, easing: "easeOut" },
            { timeSeconds: 1, degrees: 8, easing: "easeIn" },
          ],
        }]);
        const finalized = await session.finalizeAnimation(edited.animationId);
        return { animationId: finalized.animationId, revision: finalized.revision, finalized: true };
      },
      async showSticker() { return "Here is the animation."; },
    });

    const turn = await animateTurnOn(db, "owner-one-layer", sticker.stickerId, baseRevisionId);
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect(refusedCrossLayerEdit).toContain("edit_layer_animation only changes omg_text");
    const document = StickerDocumentSchema.parse(
      (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, turn.jobId)).then(firstRow))!.documentJson,
    );
    const hero = document.layers.find((layer) => layer.id === "hero");
    const text = document.layers.find((layer) => layer.id === "omg_text");
    // Untouched by the edit, and still carrying exactly what create_animation gave it.
    expect(hero?.animation.scale.map((frame) => frame.x)).toEqual([1, 1.1]);
    expect(hero?.animation.rotation).toHaveLength(0);
    // Replaced, not merged: the scale the edited layer used to have went with the operations it
    // replaced, which is what makes the tool a restatement of one layer rather than a patch.
    expect(text?.animation.rotation.map((frame) => frame.degrees)).toEqual([-8, 8]);
    expect(text?.animation.scale).toHaveLength(0);

    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, turn.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system");
    expect(toolRows.map((message) => message.content)).toEqual([
      "animate-sticker", "create_animation", "edit_layer_animation", "edit_layer_animation #2",
      "finalize_animation", "show-sticker",
    ]);
    expect(toolRows.find((message) => message.content === "edit_layer_animation")?.status).toBe("failed");
    expect(toolRows.find((message) => message.content === "edit_layer_animation #2")?.status).toBe("complete");
    await close();
  }, 30_000);

  it("animates the first generation before anything has been accepted", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-first", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-first", { title: "Wave", kind: "animated", prompt: "Wave", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-first", sticker.stickerId, "A waving hand");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.activeRevisionId).toBeNull();

    // Nothing has ever been accepted, so there is no chain to walk: this candidate is the project.
    const animateTurn = await animateTurnOn(db, "owner-first", sticker.stickerId, baseTurn.jobId);
    expect((await stickerGenerationWorkflow(animateTurn.jobId)).workflowStatus).toBe("succeeded");
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).then(firstRow))
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
    const baseTurn = await drawnAnimatedBase(db, "owner-unkept", sticker.stickerId, "OMG");
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
    expect((await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, addTurn.jobId)).then(firstRow))?.candidateState)
      .toBe("candidate");

    const animateTurn = await createChatTurn(db, "owner-unkept", sticker.stickerId, {
      text: "Animate the new artwork",
      intent: "chat",
      baseRevisionId: addTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animateTurn.jobId)).workflowStatus).toBe("succeeded");

    const turnRows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, animateTurn.jobId)).orderBy(chatMessages.sequence);
    expect(turnRows.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual([
        "animate-sticker", "create_animation", "update_animation", "edit_layer_animation",
        "finalize_animation", "show-sticker",
      ]);
    expect(turnRows.find((message) => message.role === "assistant"))
      .toMatchObject({ kind: "animation", revisionId: animateTurn.jobId });
    expect((await db.select().from(chatMessages).where(eq(chatMessages.id, animateTurn.messageId)).then(firstRow))?.kind)
      .toBe("animation");

    // The motion branched off the candidate, and deciding about it is still the user's to make.
    const animated = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animateTurn.jobId)).then(firstRow);
    expect(animated).toMatchObject({ parentRevisionId: addTurn.jobId, candidateState: "candidate" });
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.activeRevisionId)
      .toBe(baseTurn.jobId);
    await close();
  }, 30_000);

  it("removes an app-drawn layer through the edit tool instead of handing it to the planner", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-text", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-text", { title: "OMG", kind: "animated", prompt: "OMG", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-text", sticker.stickerId, "OMG");
    await stickerGenerationWorkflow(baseTurn.jobId);
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);

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
      text: "Remove the OMG lettering",
      intent: "chat",
      baseRevisionId: textOnlyRevisionId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");

    // The point of the loop: deleting a layer the app draws is an edit, served in one turn by the
    // free operation. It used to be rewritten into a plan card the user then had to confirm.
    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(toolRows).toEqual(["edit-sticker", "edit_layers", "finalize_edit", "show-sticker"]);
    // Only the draft the base setup turned down, and it is still turned down: the edit turn drafted
    // nothing of its own.
    expect((await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .map((plan) => plan.state)).toEqual(["cancelled"]);

    // Nothing was drawn and nothing else was touched: the confetti survives exactly as it was.
    const edited = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, editTurn.jobId)).then(firstRow);
    expect(edited?.candidateState).toBe("candidate");
    expect(StickerDocumentSchema.parse(edited!.documentJson).layers).toEqual([
      StickerDocumentSchema.parse(textOnly).layers[1],
    ]);
    // Still the user's decision to make, so the sticker on screen has not changed underneath them.
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.activeRevisionId)
      .toBe(textOnlyRevisionId);
    await close();
  }, 30_000);

  it("adds, renames, and reorders layers in one edit turn without drawing anything", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-crud", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-crud", { title: "Cloud", kind: "static", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-crud", sticker.stickerId, {
      text: "Happy cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-crud", sticker.stickerId, baseTurn.jobId);

    let refused: string | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      showSticker: async () => "Added the caption above the cloud.",
      async editSticker(_input, session) {
        // The free tool cannot conjure artwork: an assetId is only real once a redraw has bought it,
        // and the model is told so in an error it can act on rather than by the turn failing.
        await session.applyOperations([
          { op: "replaceAsset", layerId: "hero", assetId: crypto.randomUUID() },
        ]).catch((error: Error) => { refused = error.message; });
        await session.applyOperations([
          {
            op: "addLayer",
            layer: {
              id: "caption", name: "Caption", type: "text", text: "OMG",
              font: "rounded", weight: "bold", paint: { type: "solid", color: "#FF0055" },
            },
          },
          { op: "renameLayer", layerId: "hero", name: "Cloud" },
          { op: "reorderLayer", layerId: "caption", index: 0 },
        ] as StickerOperationV1[]);
        const finalized = await session.finalizeEdit();
        return { revision: finalized.revision, finalized: true };
      },
    });

    const editTurn = await createChatTurn(db, "owner-crud", sticker.stickerId, {
      text: "Put an OMG caption above the cloud",
      intent: "edit",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");
    expect(refused).toMatch(/edit_image_layer/);

    const turnRows = await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId)).orderBy(chatMessages.sequence);
    expect(turnRows.filter((message) => message.role === "system").map((message) => message.content))
      .toEqual(["edit-sticker", "edit_layers", "edit_layers #2", "finalize_edit", "show-sticker"]);
    // The rejected call keeps its own failed row rather than poisoning the one that succeeded.
    expect(turnRows.find((message) => message.content === "edit_layers")?.status).toBe("failed");
    expect(turnRows.find((message) => message.content === "edit_layers #2")?.status).toBe("complete");

    const edited = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, editTurn.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(edited!.documentJson);
    expect(document.layers.map((layer) => [layer.id, layer.type, layer.name]))
      .toEqual([["caption", "text", "Caption"], ["hero", "image", "Cloud"]]);
    // Nothing was drawn, so the sticker still carries the artwork the base revision paid for.
    expect(edited).toMatchObject({ candidateState: "candidate", masterAssetId: baseTurn.jobId });
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(1);
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
    const generatedAsset = await db.select().from(assets).where(eq(assets.id, turn.jobId)).then(firstRow);
    const key = generatedAsset!.r2Key;
    expect(store.objects.has(key)).toBe(true);
    const cleanupJobId = await createCleanupJob(db, "owner-b", sticker.stickerId);
    await beginJobStep(cleanupJobId);
    const keys = await purgeStickerStep(cleanupJobId);
    expect(store.objects.has(key)).toBe(false);
    expect(await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow)).toBeTruthy();
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
    expect(await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow)).toBeUndefined();
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(0);
    expect(await db.select().from(chatMessages)).toHaveLength(0);
    expect(await db.select().from(chatAttachments)).toHaveLength(0);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(0);
    await close();
  });
  /**
   * A separated part on a transparent 1024 frame, drawn where the reference had it. Each call
   * lands its block in the next cell of a grid, so every part measures somewhere different.
   */
  async function separatedPart(index: number): Promise<Uint8Array> {
    const size = 1024;
    const pixels = Buffer.alloc(size * size * 4);
    const left = 62 + (index % 4) * 250;
    const top = 100 + Math.floor(index / 4) * 300;
    for (let y = top; y < top + 200; y += 1) {
      for (let x = left; x < left + 200; x += 1) {
        const offset = (y * size + x) * 4;
        pixels[offset] = 220;
        pixels[offset + 1] = 70;
        pixels[offset + 2] = 90;
        pixels[offset + 3] = 255;
      }
    }
    return new Uint8Array(await sharp(pixels, { raw: { width: size, height: size, channels: 4 } }).png().toBuffer());
  }

  it("places each separated part where it sat in the approved reference", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-place", createdAt: new Date(), updatedAt: new Date() });
    const mockProvider = getAiProvider();
    let drawn = 0;
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: mockProvider.routeChatTurn.bind(mockProvider),
      planSticker: mockProvider.planSticker.bind(mockProvider),
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
      selectImageReferences: mockProvider.selectImageReferences.bind(mockProvider),
      generateStickerImage: async () => {
        // What the real path does after the model answers: crop to the part, square it back up to
        // the frame size, and say where it was.
        const { bytes, subject } = await normalizeTransparentPng(await separatedPart(drawn), { subjectCrop: true });
        drawn += 1;
        return { bytes, mimeType: "image/png", subject };
      },
      refineStickerLayout: mockProvider.refineStickerLayout.bind(mockProvider),
      showSticker: mockProvider.showSticker.bind(mockProvider),
      summarizeStickerTitle: mockProvider.summarizeStickerTitle.bind(mockProvider),
    });

    const sticker = await createSticker(db, "owner-place", { title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [] });
    const planTurn = await createChatTurn(db, "owner-place", sticker.stickerId, {
      text: "Make HI appear letter by letter like a typewriter",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");
    const [proposed] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    const plan = PlanV1Schema.parse(proposed.planJson);
    const generateIds = plan.layers.filter((layer) => layer.source.kind === "generate").map((layer) => layer.layerId);
    expect(generateIds.length).toBeGreaterThanOrEqual(2);

    const confirmed = await confirmPlan(db, "owner-place", sticker.stickerId, proposed.id);
    expect((await stickerGenerationWorkflow(confirmed.jobId)).workflowStatus).toBe("succeeded");

    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, confirmed.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    for (const [index, layerId] of generateIds.entries()) {
      const expected = placementFromSubject((await cropPngToSubject(await separatedPart(index))).subject)!;
      const layer = document.layers.find((candidate) => candidate.id === layerId)!;
      const planned = plan.layers.find((candidate) => candidate.layerId === layerId)!;
      expect(layer.anchor.position.x).toBeCloseTo(expected.position.x, 6);
      expect(layer.anchor.position.y).toBeCloseTo(expected.position.y, 6);
      expect(layer.anchor.scale.x).toBeCloseTo(expected.scale.x, 6);
      expect(layer.anchor.scale.y).toBeCloseTo(expected.scale.x, 6);
      // And the plan's own guess was not what shipped.
      expect([layer.anchor.position.x, layer.anchor.position.y]).not.toEqual([planned.x, planned.y]);
      // The keyframes moved with the anchor (to the compiler's rounding).
      expect(layer.animation.position[0].timeSeconds).toBe(0);
      expect(layer.animation.position[0].x).toBeCloseTo(layer.anchor.position.x, 4);
      expect(layer.animation.position[0].y).toBeCloseTo(layer.anchor.position.y, 4);
    }
    expect(layoutDiagnostics(document).offCanvasLayerIds).toEqual([]);

    // The measurement is written beside the stored master, so a replay that reuses the asset can
    // still place it: the frame it was measured in is gone, the crop is what is stored.
    const head = await store.head(objectKey("owner-place", derivedAssetId(confirmed.jobId, 0), "image/png"));
    expect(JSON.parse(head.metadata!.subject!)).toEqual((await cropPngToSubject(await separatedPart(0))).subject);
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, confirmed.jobId));
    const replay = await executeAiJobStep(confirmed.jobId);
    expect(replay.revisionId).toBe(confirmed.jobId);
    expect(drawn).toBe(generateIds.length);
    await close();
  }, 30_000);

  it("places a drawn layer the model did not position in free canvas, and refuses to move one off it", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-free", createdAt: new Date(), updatedAt: new Date() });
    const mockProvider = getAiProvider();

    const sticker = await createSticker(db, "owner-free", { title: "Cloud", kind: "static", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await createChatTurn(db, "owner-free", sticker.stickerId, {
      text: "Happy cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(baseTurn.jobId);
    await acceptRevision(db, "owner-free", sticker.stickerId, baseTurn.jobId);

    let refused: string | undefined;
    let afterAdd: ReturnType<typeof layoutDiagnostics> | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      generateStickerImage: mockProvider.generateStickerImage.bind(mockProvider),
      selectImageReferences: mockProvider.selectImageReferences.bind(mockProvider),
      showSticker: async () => "Added a rainbow beside the cloud.",
      async editSticker(_input, session) {
        const added = await session.addImageLayer({ prompt: "A small rainbow", name: "Rainbow" });
        afterAdd = layoutDiagnostics(added.document);
        const hero = added.document.layers.find((layer) => layer.id === "hero")!;
        // A free operation that would leave the hero hanging off the left edge comes back as an
        // error naming the layer, and lands nothing.
        await session.applyOperations([{
          op: "setLayerAnimations",
          layerId: "hero",
          animations: hero.animations,
          anchor: { ...hero.anchor, position: { x: -0.2, y: 0.5 } },
        }]).catch((error: Error) => { refused = error.message; });
        const finalized = await session.finalizeEdit();
        return { revision: finalized.revision, finalized: true };
      },
    });

    const editTurn = await createChatTurn(db, "owner-free", sticker.stickerId, {
      text: "Add a rainbow next to it",
      intent: "edit",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "add",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");
    expect(refused).toMatch(/Keep every complete layer box on canvas.*hero/);
    expect(afterAdd?.offCanvasLayerIds).toEqual([]);

    const edited = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, editTurn.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(edited!.documentJson);
    expect(document.layers.map((layer) => layer.name)).toEqual(["Hero", "Rainbow"]);
    const rainbow = document.layers[1];
    // Not the centre at full size: the one placement guaranteed to hide the cloud.
    expect(rainbow.anchor.scale.x).toBeLessThan(1);
    expect(rainbow.anchor.scale.x).toBe(rainbow.anchor.scale.y);
    expect(rainbow.anchor.position).not.toEqual({ x: 0.5, y: 0.5 });
    expect(document.layers[0].anchor.position).toEqual({ x: 0.5, y: 0.5 });
    expect(layoutDiagnostics(document).offCanvasLayerIds).toEqual([]);
    await close();
  }, 30_000);

  it("generates an approvable static reference, then separates matching parts after confirmation", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-c", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-c");
    const mockProvider = getAiProvider();
    let conceptBytes: number[] | undefined;
    const generatedReferences: number[][][] = [];
    const referenceSelections: Array<Array<{ label: string; required?: boolean }>> = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: mockProvider.routeChatTurn.bind(mockProvider),
      planSticker: mockProvider.planSticker.bind(mockProvider),
      generateConceptImage: async (input) => {
        const output = await mockProvider.generateConceptImage(input);
        conceptBytes = [...output.bytes];
        return output;
      },
      selectImageReferences: async (input) => {
        if (input.candidates.some(({ label }) => label === "approved plan image")) {
          referenceSelections.push(input.candidates.map(({ label, required }) => ({ label, required })));
        }
        return mockProvider.selectImageReferences(input);
      },
      generateStickerImage: async (input) => {
        generatedReferences.push(input.references.map((reference) => [...reference.bytes]));
        return mockProvider.generateStickerImage(input);
      },
      refineStickerLayout: mockProvider.refineStickerLayout.bind(mockProvider),
      showSticker: mockProvider.showSticker.bind(mockProvider),
      summarizeStickerTitle: mockProvider.summarizeStickerTitle.bind(mockProvider),
    });

    const sticker = await createSticker(db, "owner-c", {
      title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [photo.id],
    });
    const planTurn = await createChatTurn(db, "owner-c", sticker.stickerId, {
      text: "Make HI appear letter by letter like a typewriter",
      intent: "chat",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");

    // The planning turn makes exactly the still image the user must approve, but no animation
    // parts and no candidate revision yet.
    const proposed = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(proposed).toHaveLength(1);
    expect(proposed[0].state).toBe("finalized");
    expect(proposed[0].planJson.layers.every((layer) => (
      layer.source.kind === "generate" || layer.source.kind === "existing"
    ))).toBe(true);
    // create_plan then update_plan, so the draft was revised before it was frozen.
    expect(proposed[0].revision).toBe(2);
    const [referenceAsset] = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(referenceAsset).toMatchObject({ id: proposed[0].conceptAssetId, kind: "preview", state: "ready" });
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(0);

    const planMessage = (await listChatMessages(db, "owner-c", sticker.stickerId)).data
      .find((message) => message.kind === "plan");
    expect(planMessage?.plan?.state).toBe("finalized");
    expect(planMessage?.plan?.actionable).toBe(true);
    expect(planMessage?.plan?.plan.layers.length).toBeGreaterThanOrEqual(2);

    // Each plan tool call left its own row, so the client can render the drafting sequence live.
    const planToolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, planTurn.jobId)).orderBy(chatMessages.sequence))
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
    // A user retry has a fresh job id while the immutable confirmed plan still names the original
    // confirmation job. The compose step must recover that plan through their shared source turn.
    await db.update(generationJobs).set({ state: "failed", completedAt: new Date() })
      .where(eq(generationJobs.id, confirmed.jobId));
    await db.update(chatMessages).set({ status: "failed" }).where(eq(chatMessages.id, confirmed.messageId));
    const retry = await retryFailedChatTurn(db, "owner-c", sticker.stickerId, confirmed.messageId);
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");

    expect(generatedReferences).toHaveLength(partCount);
    expect(referenceSelections).toHaveLength(partCount);
    for (const candidates of referenceSelections) {
      expect(candidates).toEqual([
        { label: "approved plan image", required: true },
        { label: "original or carried reference 1", required: undefined },
      ]);
    }
    for (const references of generatedReferences) {
      expect(references).toEqual([conceptBytes, photo.bytes]);
    }

    const composedAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(composedAssets).toHaveLength(partCount + 2);
    expect(composedAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort())
      .toEqual(Array.from({ length: partCount }, (_, index) => derivedAssetId(retry.jobId, index)).sort());
    expect(composedAssets.find((asset) => asset.kind === "preview")?.id).toBe(referenceAsset.id);

    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, retry.jobId)).then(firstRow);
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

    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, retry.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(toolRows).toContain("build-plan");
    expect(toolRows.filter((name) => name.startsWith("compose-part:"))).toHaveLength(partCount);
    expect(toolRows).toContain("view_plan_image");
    expect(toolRows).toContain("view_sticker");
    expect(toolRows).toContain("finalize_layout");

    // A step retry must not mint a second set of assets or a second revision: that is what the
    // (jobId, index) derived asset ids and the deterministic revision id are for.
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, retry.jobId));
    const replay = await executeAiJobStep(retry.jobId);
    expect(replay.revisionId).toBe(retry.jobId);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(partCount + 2);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(1);

    await close();
  });

  it("animates a planned video layer from its still and stores the clip exactly once", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-v", createdAt: new Date(), updatedAt: new Date() });
    const mockProvider = getAiProvider();
    const videoRequests: Array<{ motion: string; durationSeconds: number; keyColor: string; backdropOpaque: boolean }> = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: mockProvider.routeChatTurn.bind(mockProvider),
      planSticker: mockProvider.planSticker.bind(mockProvider),
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
      generateStickerImage: mockProvider.generateStickerImage.bind(mockProvider),
      refineStickerLayout: mockProvider.refineStickerLayout.bind(mockProvider),
      showSticker: mockProvider.showSticker.bind(mockProvider),
      summarizeStickerTitle: mockProvider.summarizeStickerTitle.bind(mockProvider),
      generateStickerVideo: async (input) => {
        // The provider is handed a URL, not bytes, so the frame it would fetch has to be sitting in
        // the store right now — and flattened, since a video model cannot take alpha.
        const key = decodeURIComponent(new URL(input.imageUrl).pathname.slice(1));
        const backdrop = await store.get(key);
        const stats = await sharp(Buffer.from(backdrop.bytes)).stats();
        videoRequests.push({
          motion: input.motion,
          durationSeconds: input.durationSeconds,
          keyColor: input.keyColor.name,
          backdropOpaque: stats.isOpaque,
        });
        return mockProvider.generateStickerVideo(input);
      },
    });

    const sticker = await createSticker(db, "owner-v", {
      title: "Spin", kind: "animated", prompt: "Spin", referenceAssetIds: [],
    });
    const planTurn = await createChatTurn(db, "owner-v", sticker.stickerId, {
      text: "Plan a letter that spins all the way round",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");

    const [proposed] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(proposed.state).toBe("finalized");
    expect(proposed.planJson.layers[0].source.kind).toBe("video");
    // The card's message tells the user which layer is a clip before they pay for it.
    expect(proposed.planJson.summary).toMatch(/video/i);
    const partCount = proposed.planJson.layers.length;

    const confirmed = await confirmPlan(db, "owner-v", sticker.stickerId, proposed.id);
    expect((await stickerGenerationWorkflow(confirmed.jobId)).workflowStatus).toBe("succeeded");

    expect(videoRequests).toEqual([{
      motion: expect.stringMatching(/turnaround/),
      durationSeconds: 2,
      keyColor: "green",
      backdropOpaque: true,
    }]);

    // The concept preview, one transparent still per layer — the clip's poster among them — and
    // the clip itself. Its timing comes off the container, not off the plan.
    const stored = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(stored).toHaveLength(partCount + 2);
    expect(stored.filter((asset) => asset.kind === "master")).toHaveLength(partCount);
    const clip = stored.find((asset) => asset.kind === "video");
    expect(clip).toMatchObject({
      id: derivedAssetId(confirmed.jobId, "video:0"),
      state: "ready",
      mimeType: "video/mp4",
      width: 480,
      height: 480,
      frameCount: 24,
      fps: 24,
      durationSeconds: 1,
      hasAlpha: false,
    });
    expect(store.objects.has(clip!.r2Key)).toBe(true);
    // The flattened frame was scratch: presigned for the provider, then swept.
    const backdropId = derivedAssetId(confirmed.jobId, "video-backdrop:0");
    expect([...store.objects.keys()].some((key) => key.includes(backdropId))).toBe(false);
    expect(stored.some((asset) => asset.id === backdropId)).toBe(false);

    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, confirmed.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the built document's first layer is not a video");
    expect(hero).toMatchObject({
      assetId: clip!.id,
      posterAssetId: derivedAssetId(confirmed.jobId, 0),
      keyColor: "green",
      frameCount: 24,
      frameRate: 24,
      playback: "loop",
      startSeconds: 0,
    });
    expect(document.fps).toBeGreaterThanOrEqual(24);
    expect(document.durationSeconds).toBeGreaterThanOrEqual(1);
    expect(document.layers.slice(1).every((layer) => layer.type === "image")).toBe(true);

    const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, confirmed.jobId));
    const stages = events.map((event) => (event.dataJson as { stage?: string }).stage);
    expect(stages).toContain("composing_part");
    expect(stages).toContain("composing_video");
    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, confirmed.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system").map((message) => message.content);
    expect(toolRows.filter((name) => name.startsWith("compose-video"))).toHaveLength(1);

    // A step retry after the clip landed must not buy a second one.
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, confirmed.jobId));
    const replay = await executeAiJobStep(confirmed.jobId);
    expect(replay.revisionId).toBe(confirmed.jobId);
    expect(videoRequests).toHaveLength(1);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId))).toHaveLength(partCount + 2);

    await close();
  });

  it.each([false, true])("turns an image layer into a clip and keeps its artwork (direct chat tool: %s)", async (direct) => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-clip", createdAt: new Date(), updatedAt: new Date() });
    const mockProvider = getAiProvider();
    const videoRequests: Array<{ motion: string; durationSeconds: number; keyColor: string; backdropOpaque: boolean }> = [];
    // Filled by the scripted loop below, so the refusals can be read as the model would see them:
    // as the text of a tool error, in the same turn that is still free to carry on afterwards.
    let refusedUnknownLayer = "";
    let refusedSecondClip = "";
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: direct
        ? async (input) => ({ type: "generate_video", instruction: "slow 360° turntable rotation, one full turn", layerId: input.document!.layers[0].id, durationSeconds: 2 })
        : mockProvider.routeChatTurn.bind(mockProvider),
      planSticker: mockProvider.planSticker.bind(mockProvider),
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
      generateStickerImage: mockProvider.generateStickerImage.bind(mockProvider),
      refineStickerLayout: mockProvider.refineStickerLayout.bind(mockProvider),
      showSticker: mockProvider.showSticker.bind(mockProvider),
      summarizeStickerTitle: mockProvider.summarizeStickerTitle.bind(mockProvider),
      generateStickerVideo: async (input) => {
        // The provider takes a URL, not bytes, so the frame it would fetch has to be in the store
        // right now — and flattened, since no video model takes alpha.
        const key = decodeURIComponent(new URL(input.imageUrl).pathname.slice(1));
        const stats = await sharp(Buffer.from((await store.get(key)).bytes)).stats();
        videoRequests.push({
          motion: input.motion,
          durationSeconds: input.durationSeconds,
          keyColor: input.keyColor.name,
          backdropOpaque: stats.isOpaque,
        });
        return mockProvider.generateStickerVideo(input);
      },
      editSticker: async (input, session) => {
        if (direct) throw new Error("Direct video generation must bypass the editing agent");
        const hero = input.document.layers[0];
        refusedUnknownLayer = await session
          .createVideoLayer({ layerId: "no_such_layer", motion: "turn around", durationSeconds: 2 })
          .then(() => "", (error: Error) => error.message);
        const landed = await session.createVideoLayer({
          layerId: hero.id,
          motion: "slow 360° turntable rotation, one full turn",
          durationSeconds: 2,
        });
        // The budget, from inside the turn that already spent it. A loop that keeps asking is told
        // to stop rather than billed twice.
        refusedSecondClip = await session
          .createVideoLayer({ layerId: hero.id, motion: "and again", durationSeconds: 2 })
          .then(() => "", (error: Error) => error.message);
        const finalized = await session.finalizeEdit();
        return { revision: finalized.revision, finalized: landed.revision > 0 };
      },
    });

    const sticker = await createSticker(db, "owner-clip", {
      title: "Turn", kind: "animated", prompt: "A red mask", referenceAssetIds: [],
    });
    const baseTurn = await drawnAnimatedBase(db, "owner-clip", sticker.stickerId, "A red mask");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    await acceptRevision(db, "owner-clip", sticker.stickerId, baseTurn.jobId);
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);
    const base = StickerDocumentSchema.parse(baseRevision!.documentJson);
    const still = base.layers[0];
    if (still.type !== "image") throw new Error("the drawn base is not a single image layer");

    const editTurn = await createChatTurn(db, "owner-clip", sticker.stickerId, {
      text: "Make it a full turnaround of the character",
      intent: "chat",
      baseRevisionId: baseTurn.jobId,
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(editTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(videoRequests).toEqual([{
      motion: "slow 360° turntable rotation, one full turn",
      durationSeconds: 2,
      // Measured off the artwork rather than guessed from a prompt: the mock draws a pink subject,
      // which is safe against green.
      keyColor: "green",
      backdropOpaque: true,
    }]);
    if (!direct) {
      expect(refusedUnknownLayer).toMatch(/Unknown layer no_such_layer/);
      expect(refusedSecondClip).toMatch(/already made a clip/);
    }

    const clip = (await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId)))
      .find((asset) => asset.kind === "video");
    expect(clip).toMatchObject({
      id: derivedAssetId(editTurn.jobId, "edit-video-0"),
      state: "ready",
      mimeType: "video/mp4",
      frameCount: 24,
      fps: 24,
      hasAlpha: false,
    });
    // The flattened frame the provider was pointed at is scratch, swept whichever path ordered it.
    const backdropId = derivedAssetId(editTurn.jobId, "edit-video-backdrop-0");
    expect([...store.objects.keys()].some((key) => key.includes(backdropId))).toBe(false);
    expect(await db.select().from(assets).where(eq(assets.id, backdropId)).then(firstRow)).toBeUndefined();

    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, editTurn.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    expect(document.layers).toHaveLength(base.layers.length);
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the edited document's first layer is not a video");
    // A swap, not a new layer landing on top: same id, same name, same place, same anchor, and the
    // artwork it was animated from still standing as the poster.
    expect(hero).toMatchObject({
      id: still.id,
      name: still.name,
      assetId: clip!.id,
      posterAssetId: still.assetId,
      keyColor: "green",
      frameCount: 24,
      frameRate: 24,
      playback: "loop",
      startSeconds: 0,
    });
    expect(hero.anchor).toEqual(still.anchor);
    // The document already sampled fast enough and ran long enough for this clip, so its timing
    // was left alone rather than rewritten for the sake of it.
    expect(document.fps).toBe(base.fps);
    expect(document.durationSeconds).toBe(base.durationSeconds);
    // The library card falls back to the poster instead of going blank, now that the only image
    // layer the sticker had is the one that became a clip.
    expect(revision).toMatchObject({ masterAssetId: still.assetId, previewAssetId: still.assetId });

    const toolRows = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, editTurn.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system");
    expect(toolRows.map((message) => message.content))
      .toEqual(direct
        ? ["generate-video", "create_video", "finalize_edit", "show-sticker"]
        : ["edit-sticker", "create_video", "create_video #2", "create_video #3", "finalize_edit", "show-sticker"]);
    // The refused calls are rows of their own rather than a retry re-marking the one that failed.
    expect(toolRows.filter((message) => message.status === "failed").map((message) => message.content))
      .toEqual(direct ? [] : ["create_video", "create_video #3"]);

    // A step retry after the clip landed must not buy a second one.
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, editTurn.jobId));
    expect((await executeAiJobStep(editTurn.jobId)).revisionId).toBe(editTurn.jobId);
    expect(videoRequests).toHaveLength(1);

    await close();
  }, 30_000);

  /**
   * The turn's attachments, as the agents are given them.
   *
   * Compared by bytes rather than by identity: the point of these tests is that the pixels the user
   * uploaded reach the model, not that some array of the right length was constructed.
   */
  const attachedBytes = (references: Array<{ bytes: Uint8Array }>) =>
    references.map((reference) => [...reference.bytes]);

  async function attachablePhoto(
    db: Awaited<ReturnType<typeof createTestDatabase>>["db"],
    store: MemoryObjectStore,
    ownerId: string,
  ) {
    const id = crypto.randomUUID();
    const key = objectKey(ownerId, id, "image/png");
    const bytes = new Uint8Array([137, 80, 78, 71]);
    await db.insert(assets).values({
      id, ownerId, kind: "reference", state: "ready", r2Key: key, mimeType: "image/png",
      byteSize: bytes.byteLength, createdAt: new Date(), readyAt: new Date(),
    });
    await store.put(key, { bytes, contentType: "image/png" });
    return { id, bytes: [...bytes] };
  }

  it("shows the router and the planner the photo the user attached", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-sees", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-sees");

    let routed: number[][] | undefined;
    let planned: number[][] | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => {
        routed = attachedBytes(input.references);
        return { type: "plan", instruction: input.instruction };
      },
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 1024, height: 1024, channels: 4, background: { r: 200, g: 120, b: 60, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        planned = attachedBytes(input.references);
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Me", summary: "A sticker of you.", kind: "animated",
          conceptPrompt: "A polished sticker of the person in the attached photo, waving, filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "hero", name: "Me",
            source: { kind: "generate", prompt: "The person from the photo as a sticker on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-sees", { title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [photo.id] });
    const turn = await createChatTurn(db, "owner-sees", sticker.stickerId, {
      text: "Make a sticker of me",
      intent: "chat",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    // Both models used to be told a number of attachments and nothing else, which is how a design
    // for "a sticker of me" got drafted without anyone having looked at the person.
    expect(routed).toEqual([photo.bytes]);
    expect(planned).toEqual([photo.bytes]);
    await close();
  });

  it("shows the router a previous plan image and reuses it when a text-only follow-up asks", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-plan-image", createdAt: new Date(), updatedAt: new Date() });

    const conceptBytes = new Uint8Array(await sharp({
      create: { width: 1024, height: 1024, channels: 4, background: { r: 230, g: 90, b: 150, alpha: 1 } },
    }).png().toBuffer());
    const generatedSubject = await sharp({
      create: { width: 640, height: 640, channels: 4, background: { r: 80, g: 170, b: 240, alpha: 1 } },
    }).png().toBuffer();
    const generatedBytes = new Uint8Array(await sharp({
      create: { width: 1024, height: 1024, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
    }).composite([{ input: generatedSubject, left: 192, top: 192 }]).png().toBuffer());
    let routedPlanImage: number[] | undefined;
    let generatedReferences: number[][] | undefined;
    let generatedMode: "generate" | "conversation_edit" | undefined;

    setAiProviderForTests({
      ...unusedAiProvider,
      planSticker: async (_input, session) => {
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Cartoon Words", summary: "Cartoon lettering with a playful bounce.", kind: "animated",
          conceptPrompt: "Colourful cartoon lettering as a polished sticker filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "words", name: "Words",
            source: { kind: "generate", prompt: "Colourful cartoon lettering on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
      generateConceptImage: async () => ({ bytes: conceptBytes, mimeType: "image/png" }),
      routeChatTurn: async (input) => {
        const planVisual = input.priorArt.find((visual) => visual.label.includes("previous plan"));
        routedPlanImage = planVisual ? [...planVisual.image.bytes] : undefined;
        return { type: "generate", instruction: input.instruction, usePlanImage: true };
      },
      generateStickerImage: async (input) => {
        generatedReferences = attachedBytes(input.references);
        generatedMode = input.mode;
        return { bytes: generatedBytes, mimeType: "image/png" };
      },
      showSticker: async () => "Generated from the plan image.",
    });

    const sticker = await createSticker(db, "owner-plan-image", {
      title: "Cartoon Words", kind: "animated", prompt: "Cartoon words", referenceAssetIds: [],
    });
    const planTurn = await createChatTurn(db, "owner-plan-image", sticker.stickerId, {
      text: "Plan some cartoon words", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");

    const [pending] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    await cancelPlan(db, "owner-plan-image", sticker.stickerId, pending.id);

    const reuseTurn = await createChatTurn(db, "owner-plan-image", sticker.stickerId, {
      text: "Use the plan image as the reference", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(reuseTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(routedPlanImage?.length).toBeGreaterThan(0);
    expect(generatedReferences?.[0]).toEqual(routedPlanImage);
    expect(generatedMode).toBe("conversation_edit");
    await close();
  });

  it("shows the planner the existing artwork on a turn with nothing attached", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-replan", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-replan", { title: "Cloud", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-replan", sticker.stickerId, "Happy cloud");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);
    await acceptRevision(db, "owner-replan", sticker.stickerId, baseRevision!.id);

    let planned: { references: number; priorArt: Array<{ label: string; bytes: number }> } | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 1024, height: 1024, channels: 4, background: { r: 200, g: 120, b: 60, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        planned = {
          references: input.references.length,
          priorArt: input.priorArt.map((visual) => ({
            label: visual.label,
            bytes: visual.image.bytes.byteLength,
          })),
        };
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Cloud", summary: "Bigger cloud.", kind: "animated",
          conceptPrompt: "A polished sticker of a happy cloud, filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "hero", name: "Cloud",
            source: { kind: "generate", prompt: "A happy cloud on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const replan = await createChatTurn(db, "owner-replan", sticker.stickerId, {
      text: "make the cloud bigger",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(replan.jobId)).workflowStatus).toBe("succeeded");

    // The regression this guards: the planner was shown `references` and nothing else, so a turn
    // where the user attached nothing — every "make it bigger", every re-plan — was designed from
    // JSON and prose with no sight of the artwork, and came back having redrawn things nobody had
    // asked it to touch.
    expect(planned?.references).toBe(0);
    expect(planned?.priorArt.length).toBeGreaterThan(0);
    // An animated project renders as a sheet of sampled frames, and the label has to say so — a
    // planner that reads one as a single composition sees the same subject drawn six times over.
    expect(planned?.priorArt[0].label).toContain("contact sheet");
    expect(planned?.priorArt[0].label).toContain("review render");
    // Real pixels, not an empty buffer that happens to satisfy the type.
    for (const visual of planned!.priorArt) expect(visual.bytes).toBeGreaterThan(0);
    await close();
  });

  it("keeps a capture usable on later turns that attach nothing", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-capture", createdAt: new Date(), updatedAt: new Date() });

    // A Live Photo capture, cut out on device: 12 frames in a 4x3 atlas, the shape the iOS client
    // uploads and the shape a plan has to copy verbatim.
    const captureId = crypto.randomUUID();
    const captureKey = objectKey("owner-capture", captureId, "image/png");
    const captureBytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    await db.insert(assets).values({
      id: captureId, ownerId: "owner-capture", kind: "sequence", state: "ready",
      r2Key: captureKey, mimeType: "image/png", byteSize: captureBytes.byteLength,
      frameCount: 12, fps: 24, sequenceColumns: 4, sequenceRows: 3,
      createdAt: new Date(), readyAt: new Date(),
    });
    await store.put(captureKey, { bytes: captureBytes, contentType: "image/png" });

    const sequenceLayer = (assetId: string) => ({
      layerId: "hero", name: "Me",
      source: { kind: "sequence", assetId, columns: 4, rows: 3, frameCount: 12, frameRate: 24 },
      x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
    });
    const planWith = (title: string, layers: unknown[]) => PlanV1Schema.parse({
      title, summary: `${title}.`, kind: "animated",
      conceptPrompt: "A polished sticker of the person in the capture, filling the frame.",
      timing: { durationSeconds: 2, fps: 30, loop: "loop" },
      layers,
    });

    const seen: Array<{ captures: string[]; priorArt: string[]; attached: number }> = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 512, height: 512, channels: 4, background: { r: 30, g: 90, b: 200, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        seen.push({
          captures: input.sequenceAssets.map((asset) =>
            `${asset.assetId}:${asset.columns}x${asset.rows}:${asset.frameCount}@${asset.frameRate}`),
          priorArt: input.priorArt.map((visual) => visual.label),
          attached: input.references.length,
        });
        const created = await session.createPlan(planWith("Me", [sequenceLayer(captureId)]));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-capture", {
      title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [captureId],
    });
    const first = await createChatTurn(db, "owner-capture", sticker.stickerId, {
      text: "我要我的头像有个会动的皇冠",
      intent: "chat",
      attachments: [{ assetId: captureId, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");

    // The turn that used to break it: a request to add text, with nothing attached.
    const second = await createChatTurn(db, "owner-capture", sticker.stickerId, {
      text: "加一个文字： 游戏大神",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(second.jobId)).workflowStatus).toBe("succeeded");

    expect(seen).toHaveLength(2);
    const [attachTurn, textOnlyTurn] = seen;
    expect(attachTurn.captures).toEqual([`${captureId}:4x3:12@24`]);

    // The regression. This turn attached nothing, and the capture used to vanish with it — not just
    // from view but from `sequenceAssets`, which made the `sequence` source illegal and left the
    // planner no way to keep the user's own footage. It answered by replacing them with a generate
    // layer describing their face.
    expect(textOnlyTurn.attached).toBe(0);
    expect(textOnlyTurn.captures).toEqual([`${captureId}:4x3:12@24`]);
    // And it is shown the footage, not merely told the numbers.
    expect(textOnlyTurn.priorArt[0]).toContain("captured");
    expect(textOnlyTurn.priorArt[0]).toContain("contact sheet");

    // The plan the second turn produced still points at the capture rather than at a drawn stand-in.
    const stored = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    const newest = stored.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime()).at(-1);
    expect(newest?.planJson.layers[0].source).toMatchObject({ kind: "sequence", assetId: captureId });
    await close();
  });

  it("still renders the concept from the user's photo on a later turn that attaches nothing", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-likeness", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-likeness");

    const conceptReferences: number[][][] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async (input) => {
        conceptReferences.push(attachedBytes(input.references));
        return {
          bytes: new Uint8Array(await sharp({
            create: { width: 1024, height: 1024, channels: 4, background: { r: 90, g: 60, b: 30, alpha: 1 } },
          }).png().toBuffer()),
          mimeType: "image/png",
        };
      },
      planSticker: async (input, session) => {
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Me", summary: "A sticker of you.", kind: "animated",
          conceptPrompt: "The person in the supplied reference photo, as a polished sticker filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "portrait", name: "Me",
            source: { kind: "generate", prompt: "The person in the supplied reference photo, on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-likeness", {
      title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [photo.id],
    });
    const first = await createChatTurn(db, "owner-likeness", sticker.stickerId, {
      text: "Add a crown on top of my head",
      intent: "chat",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");

    const second = await createChatTurn(db, "owner-likeness", sticker.stickerId, {
      text: "Add text game master",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(second.jobId)).workflowStatus).toBe("succeeded");

    // The image model is the only thing in the pipeline that ever sees a photograph, and it used to
    // see one only on the turn it was uploaded. A second turn with nothing attached and no built
    // document rendered its concept from the plan's prose alone — and prose cannot carry a face, so
    // the person came back a stranger who merely matched the adjectives.
    expect(conceptReferences).toHaveLength(2);
    expect(conceptReferences[0]).toEqual([photo.bytes]);
    expect(conceptReferences[1]).toEqual([photo.bytes]);
    await close();
  });

  it("shows the animator the photo the user attached", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-animates", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-animates");

    const sticker = await createSticker(db, "owner-animates", { title: "Wave", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-animates", sticker.stickerId, "Happy cloud");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    await acceptRevision(db, "owner-animates", sticker.stickerId, baseTurn.jobId);

    let animated: number[][] | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      animateSticker: async (input, session) => {
        animated = attachedBytes(input.references);
        const created = await session.createAnimation([{
          op: "setScaleKeyframes",
          layerId: "hero",
          keyframes: [
            { timeSeconds: 0, x: 1, y: 1, easing: "easeOut" },
            { timeSeconds: 1, x: 1.1, y: 1.1, easing: "easeIn" },
          ],
        }]);
        const finalized = await session.finalizeAnimation(created.animationId);
        return { animationId: finalized.animationId, revision: finalized.revision, finalized: true };
      },
      showSticker: async () => "Here is the motion.",
    });

    const turn = await createChatTurn(db, "owner-animates", sticker.stickerId, {
      text: "Make it wave like the person in this photo",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: baseTurn.jobId,
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    // The animation loop draws nothing, so an attachment on an animate turn is only ever there to
    // be looked at — and until now it was the one turn that never loaded it at all.
    expect(animated).toEqual([photo.bytes]);
    await close();
  }, 30_000);

  it("revises a built sticker by reusing its artwork instead of paying to redraw it", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-f", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-f", { title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [] });
    const first = await createChatTurn(db, "owner-f", sticker.stickerId, {
      text: "Compose the word HI letter by letter", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(first.jobId);
    const drafted = (await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId))).at(0)!;
    const built = await confirmPlan(db, "owner-f", sticker.stickerId, drafted.id);
    await stickerGenerationWorkflow(built.jobId);
    await acceptRevision(db, "owner-f", sticker.stickerId, built.jobId);

    const originalAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    const originalAssetIds = originalAssets.map((asset) => asset.id).sort();
    expect(originalAssets.some((asset) => asset.kind === "preview")).toBe(true);

    // A second planning turn against the sticker that now exists. Nothing about it is new artwork,
    // so the plan carries the layers it already has rather than describing them again.
    const revise = await createChatTurn(db, "owner-f", sticker.stickerId, {
      text: "Plan it tighter", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(revise.jobId)).workflowStatus).toBe("succeeded");

    const revised = (await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .find((row) => row.state === "finalized")!;
    const reusedIds = revised.planJson.layers.map((layer) => (layer.source as { assetId?: string }).assetId);
    expect(revised.planJson.layers.every((layer) => layer.source.kind === "existing")).toBe(true);
    expect(reusedIds.every((assetId) => originalAssetIds.includes(assetId!))).toBe(true);

    // The card says as much: nothing to generate, so the user is asked to build rather than to pay.
    const card = (await listChatMessages(db, "owner-f", sticker.stickerId)).data
      .filter((message) => message.kind === "plan").at(-1);
    expect(card?.plan?.generationCount).toBe(0);

    const rebuilt = await confirmPlan(db, "owner-f", sticker.stickerId, revised.id);
    expect((await stickerGenerationWorkflow(rebuilt.jobId)).workflowStatus).toBe("succeeded");

    // Re-planning creates one new static reference for the new decision. Building it creates no new
    // master images, and the document still points at exactly the artwork previously approved.
    const finalAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(finalAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort())
      .toEqual(originalAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort());
    expect(finalAssets.map((asset) => asset.id).sort())
      .toEqual([...originalAssetIds, revised.conceptAssetId!].sort());
    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, rebuilt.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    expect(document.layers.flatMap((layer) => (layer.type === "image" ? [layer.assetId] : [])).sort())
      .toEqual(reusedIds.sort());
    await close();
  });

  it.each(["draft", "finalized"] as const)("keeps follow-up chat in planning while a plan is %s", async (state) => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-pending", createdAt: new Date(), updatedAt: new Date() });
    const sticker = await createSticker(db, "owner-pending", {
      title: "HI", kind: "static", prompt: "HI", referenceAssetIds: [],
    });
    const first = await createChatTurn(db, "owner-pending", sticker.stickerId, {
      text: "Compose the word HI from separate letters", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");
    const [pending] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    await db.update(planRows).set({ state }).where(eq(planRows.id, pending.id));
    const mockProvider = getAiProvider();
    const instructions: string[] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      planSticker: async (input, session) => {
        instructions.push(input.instruction);
        expect(input.history).toContain("Current pending plan");
        return mockProvider.planSticker(input, session);
      },
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
    });
    for (const text of ["Make the letters blue", "Add more spacing"]) {
      const followup = await createChatTurn(db, "owner-pending", sticker.stickerId, {
        text, intent: "chat", attachments: [], imagePlacement: "replace",
      });
      expect((await stickerGenerationWorkflow(followup.jobId)).workflowStatus).toBe("succeeded");
    }
    expect(instructions).toEqual(["Make the letters blue", "Add more spacing"]);
    const rows = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(rows).toHaveLength(3);
    expect(rows.filter((row) => row.state === "finalized")).toHaveLength(1);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId)))
      .toHaveLength(0);
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
    expect((await db.select().from(planRows).where(eq(planRows.id, live.id)).then(firstRow))?.decisionReason)
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
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId)))
      .toEqual([expect.objectContaining({ kind: "preview", state: "ready" })]);
    await close();
  });

  it("plans an animated creation however plain its prompt, and draws a static one", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-f", createdAt: new Date(), updatedAt: new Date() });

    // "A happy cloud" asks for no per-element effect at all. It is still planned, because the kind
    // is the user's standing choice and one flat image would quietly hand them the static sticker
    // they did not pick — the reading of their words is not what decides this.
    const animated = await createSticker(db, "owner-f", {
      title: "Cloud", kind: "animated", prompt: "A happy cloud", referenceAssetIds: [],
    });
    const animatedTurn = await createChatTurn(db, "owner-f", animated.stickerId, {
      text: "A happy cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animatedTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, animated.stickerId)))
      .toHaveLength(1);
    // Only the static visual reference is drawn until the user confirms the plan.
    expect(await db.select().from(assets).where(eq(assets.stickerId, animated.stickerId)))
      .toEqual([expect.objectContaining({ kind: "preview", state: "ready" })]);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animatedTurn.jobId)).then(firstRow))
      .toBeFalsy();

    // A static project never moves, so there is nothing to design as layers: it is drawn straight.
    const still = await createSticker(db, "owner-f", {
      title: "Cloud", kind: "static", prompt: "A happy cloud", referenceAssetIds: [],
    });
    const stillTurn = await createChatTurn(db, "owner-f", still.stickerId, {
      text: "A happy cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(stillTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, still.stickerId))).toHaveLength(0);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, stillTurn.jobId)).then(firstRow)).toBeTruthy();
    await close();
  });

  it("draws a quick-mode turn on the quick image model and leaves every other turn alone", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-quick", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-quick");

    const mockProvider = getAiProvider();
    const drawnQuickly: Array<boolean | undefined> = [];
    // Everything a turn can ask a reasoning model for, counted. Quick mode's whole latency budget is
    // spent on these rather than on the draw: each is a vision call on the orchestrator model, and
    // together they cost several times the two seconds the quick model needs for the picture.
    const orchestrated = { selected: 0, shown: 0, named: 0 };
    setAiProviderForTests({
      ...unusedAiProvider,
      selectImageReferences: async (input) => {
        orchestrated.selected += 1;
        return mockProvider.selectImageReferences(input);
      },
      generateStickerImage: async (input) => {
        drawnQuickly.push(input.quick);
        return mockProvider.generateStickerImage(input);
      },
      editSticker: mockProvider.editSticker.bind(mockProvider),
      showSticker: async (...args) => {
        orchestrated.shown += 1;
        return mockProvider.showSticker(...args);
      },
      summarizeStickerTitle: async (input) => {
        orchestrated.named += 1;
        return mockProvider.summarizeStickerTitle(input);
      },
    });

    const sticker = await createSticker(db, "owner-quick", {
      title: "Wink", kind: "static", prompt: "A winking cat", referenceAssetIds: [photo.id],
    });
    const fromMessages = await createChatTurn(db, "owner-quick", sticker.stickerId, {
      text: "A winking cat",
      intent: "generate",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
      quick: true,
    });
    expect((await stickerGenerationWorkflow(fromMessages.jobId, true)).workflowStatus).toBe("succeeded");

    // One model call for the whole turn: the drawing. Not the reference selector, not the caption,
    // not the renaming — all three deliberate on artwork nobody in Messages is going to read a
    // sentence about, while the person who asked watches a spinner.
    expect(orchestrated).toEqual({ selected: 0, shown: 0, named: 0 });
    // The transcript still gets its assistant message, or the main app has a turn it cannot draw.
    const transcript = await listChatMessages(db, "owner-quick", sticker.stickerId, { limit: 10 });
    expect(transcript.data.at(-1)).toMatchObject({ role: "assistant", content: "Here's your sticker." });

    // The same project, carried on in the main app: the flag belongs to the turn, so opening a
    // sticker made in Messages does not condemn the rest of its life to the cheaper model — or to
    // the shortcuts, which is why the orchestrator counts move again here.
    const fromApp = await createChatTurn(db, "owner-quick", sticker.stickerId, {
      text: "Give it a party hat", intent: "edit", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(fromApp.jobId)).workflowStatus).toBe("succeeded");

    expect(drawnQuickly).toEqual([true, false]);
    expect(orchestrated.named).toBe(1);
    await close();
  });

  it("renames the sticker from its transcript when the turn finishes", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title", createdAt: new Date(), updatedAt: new Date() });

    const summarized: AiTitleContext[] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async (input) => {
        summarized.push(input);
        // Quoted and padded, the way a model that ignored half the instruction answers.
        return ' "Sunglasses Cat" ';
      },
    });

    const prompt = "make me a cat sticker wearing tiny sunglasses please";
    const sticker = await createSticker(db, "owner-title", {
      title: prompt, kind: "static", prompt, referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title", sticker.stickerId, {
      text: prompt, intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title)
      .toBe("Sunglasses Cat");
    expect(summarized).toHaveLength(1);
    expect(summarized[0].currentTitle).toBe(prompt);
    expect(summarized[0].history).toContain(`user: ${prompt}`);
    // Tool-call rows are the turn's machinery. `reply` is the one this turn opened, and naming the
    // sticker after it is exactly what filtering them out prevents.
    expect(summarized[0].history).not.toContain("system: reply");
    await close();
  });

  it("keeps the old name, and the finished turn, when naming fails", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title-fail", createdAt: new Date(), updatedAt: new Date() });

    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async () => { throw new Error("naming timed out"); },
    });

    const sticker = await createSticker(db, "owner-title-fail", {
      title: "Wave", kind: "static", prompt: "Wave", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title-fail", sticker.stickerId, {
      text: "Hello", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).then(firstRow))?.state)
      .toBe("succeeded");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title)
      .toBe("Wave");
    await close();
  });

  it("clips a name too long for a library row at a word boundary", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title-long", createdAt: new Date(), updatedAt: new Date() });

    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async () =>
        "A Very Enthusiastic Cat Wearing Tiny Mirrored Sunglasses On A Skateboard",
    });

    const sticker = await createSticker(db, "owner-title-long", {
      title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title-long", sticker.stickerId, {
      text: "Cat on a skateboard", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(turn.jobId);

    const title = (await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title;
    expect(title).toBe("A Very Enthusiastic Cat Wearing Tiny Mirrored");
    expect(title!.length).toBeLessThanOrEqual(48);
    await close();
  });
});
