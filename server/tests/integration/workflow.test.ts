import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { StickerDocumentV1Schema } from "@/lib/contracts/sticker";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, generationEvents, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { derivedAssetId } from "@/lib/services/assets";
import { cancelPlan, confirmPlan } from "@/lib/services/plans";
import { acceptRevision, bindExports, createCandidateRevision, createChatTurn, createCleanupJob, createSticker, listChatMessages, retryFailedChatTurn } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { beginJobStep, executeAiJobStep, failJobStep, finalizeStickerPurgeStep, purgeStickerStep, sweepStickerObjectsStep } from "@/workflows/sticker-generation/steps";

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
    await expect(createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Animate before confirmation",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: baseRevision!.id,
      attachments: [],
      imagePlacement: "replace",
    })).rejects.toMatchObject({ code: "ANIMATION_BASE_NOT_ACCEPTED" });
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
    const pingPongDocument = StickerDocumentV1Schema.parse({ ...animationRevision!.documentJson, loop: "pingPong" });
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
      { id: renditionIds.gif, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "gif", state: "ready", r2Key: objectKey("owner-a", renditionIds.gif, "image/gif"), mimeType: "image/gif", byteSize: 200_000, width: 1024, height: 1024, frameCount: 120, durationSeconds: 4, fps: 30, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.mp4, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "mp4", state: "ready", r2Key: objectKey("owner-a", renditionIds.mp4, "video/mp4"), mimeType: "video/mp4", byteSize: 300_000, width: 1024, height: 1024, frameCount: 120, durationSeconds: 4, fps: 30, sha256: "b".repeat(64), hasAlpha: false, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", renditionIds.system, "image/gif"), mimeType: "image/gif", byteSize: 400_000, width: 408, height: 408, frameCount: 60, durationSeconds: 4, fps: 15, sha256: "c".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
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
    expect(StickerDocumentV1Schema.parse(publishedRevision!.documentJson).mp4Background.type).toBe("linearGradient");
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
    const document = StickerDocumentV1Schema.parse(revision!.documentJson);
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
