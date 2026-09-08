import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { StickerDocumentSchema, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { layoutDiagnostics } from "@/lib/layout/composition";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { assets, chatMessages, generationEvents, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { acceptRevision, bindExports, createCandidateRevision, createChatTurn, createSticker, listChatMessages, retryFailedChatTurn } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { unusedAiProvider, resetWorkflowTestState, drawnAnimatedBase } from "@/tests/helpers/workflow";

describe("durable sticker workflow: motion", () => {
  afterEach(resetWorkflowTestState);

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
});
