import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider, setAiProviderForTests } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { cropPngToSubject } from "@/lib/images/subject-bounds";
import { layoutDiagnostics } from "@/lib/layout/composition";
import { placementFromSubject } from "@/lib/layout/placement";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, generationEvents, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { derivedAssetId } from "@/lib/services/assets";
import { confirmPlan } from "@/lib/services/plans";
import { acceptRevision, createChatTurn, createCleanupJob, createSticker, listChatMessages, retryFailedChatTurn } from "@/lib/services/stickers";
import { MemoryObjectStore, normalizeTransparentPng, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { beginJobStep, executeAiJobStep, failJobStep, finalizeStickerPurgeStep, purgeStickerStep, sweepStickerObjectsStep } from "@/workflows/sticker-generation/steps";
import { unusedAiProvider, resetWorkflowTestState, drawnAnimatedBase, attachablePhoto } from "@/tests/helpers/workflow";

describe("durable sticker workflow: composition", () => {
  afterEach(resetWorkflowTestState);

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

  it("generates at most three parts together and preserves placement with out-of-order completion", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-place", createdAt: new Date(), updatedAt: new Date() });
    const mockProvider = getAiProvider();
    let drawn = 0;
    let active = 0;
    let peakActive = 0;
    let releaseFirstBatch!: () => void;
    const firstBatchReady = new Promise<void>((resolve) => { releaseFirstBatch = resolve; });
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: mockProvider.routeChatTurn.bind(mockProvider),
      planSticker: mockProvider.planSticker.bind(mockProvider),
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
      selectImageReferences: mockProvider.selectImageReferences.bind(mockProvider),
      generateStickerImage: async () => {
        // What the real path does after the model answers: crop to the part, square it back up to
        // the frame size, and say where it was.
        const index = drawn++;
        active += 1;
        peakActive = Math.max(peakActive, active);
        if (drawn === 3) releaseFirstBatch();
        // A sequential implementation cannot get past this barrier.
        await firstBatchReady;
        const { bytes, subject } = await normalizeTransparentPng(await separatedPart(index), { subjectCrop: true });
        // Hold the first part back to exercise completion-based progress and stable placement.
        if (index === 0) await new Promise((resolve) => setTimeout(resolve, 150));
        active -= 1;
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
    // More than one batch exercises the cap as well as parallel execution.
    const template = plan.layers.find((layer) => layer.source.kind === "generate")!;
    while (plan.layers.length < 5) {
      plan.layers.push({ ...template, layerId: `extra-${plan.layers.length}`, name: `Part ${plan.layers.length}` });
    }
    await db.update(planRows).set({ planJson: plan }).where(eq(planRows.id, proposed.id));
    const generateIds = plan.layers.filter((layer) => layer.source.kind === "generate").map((layer) => layer.layerId);
    expect(generateIds.length).toBeGreaterThanOrEqual(2);

    const confirmed = await confirmPlan(db, "owner-place", sticker.stickerId, proposed.id);
    expect((await stickerGenerationWorkflow(confirmed.jobId)).workflowStatus).toBe("succeeded");

    expect(peakActive).toBe(3);
    expect(active).toBe(0);
    const progressEvents = await db.select().from(generationEvents)
      .where(eq(generationEvents.jobId, confirmed.jobId)).orderBy(generationEvents.id);
    const partProgress = progressEvents.map((event) => event.dataJson)
      .filter((data) => data.stage === "composing_part");
    expect(partProgress).toHaveLength(generateIds.length);
    expect(partProgress[0].partIndex).not.toBe(0);
    expect(partProgress.map((data) => data.progress)).toEqual(
      generateIds.map((_, index) => 0.05 + 0.7 * ((index + 1) / generateIds.length)),
    );
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
    let failSecondPart = true;
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
        if (generatedReferences.length === 1 && failSecondPart) {
          failSecondPart = false;
          throw new Error("Second part provider outage");
        }
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
    expect(await stickerGenerationWorkflow(confirmed.jobId)).toEqual({ status: "failed" });
    expect(generatedReferences).toHaveLength(Math.min(partCount, 3) - 1);
    const savedPart = await db.select().from(assets)
      .where(eq(assets.id, derivedAssetId(confirmed.jobId, 0))).then(firstRow);
    expect(savedPart?.state).toBe("ready");
    const retry = await retryFailedChatTurn(db, "owner-c", sticker.stickerId, confirmed.messageId);
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");

    expect(generatedReferences).toHaveLength(partCount);
    // Only the failed part selects references again; the completed part skips both AI calls.
    expect(referenceSelections).toHaveLength(partCount + 1);
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
    expect(composedAssets.filter((asset) => !asset.r2Key.includes("/tool-previews/"))).toHaveLength(partCount + 2);
    expect(composedAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort())
      .toEqual(Array.from({ length: partCount }, (_, index) => derivedAssetId(confirmed.jobId, index)).sort());
    expect(composedAssets.find((asset) => asset.id === savedPart!.id)).toEqual(savedPart);
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

    const toolMessages = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, retry.jobId)).orderBy(chatMessages.sequence))
      .filter((message) => message.role === "system");
    const toolRows = toolMessages.map((message) => message.content);
    expect(toolRows).toContain("build-plan");
    expect(toolRows.filter((name) => name.startsWith("compose-part:"))).toHaveLength(partCount);
    expect(toolRows).toContain("view_plan_image");
    expect(toolRows).toContain("view_sticker");
    expect(toolRows).toContain("finalize_layout");
    const transcript = await listChatMessages(db, "owner-c", sticker.stickerId);
    const partCalls = transcript.data.filter((message) => message.content.startsWith("compose-part:") && toolMessages.some((tool) => tool.id === message.id));
    expect(partCalls).toHaveLength(partCount);
    for (const call of partCalls) {
      const details = JSON.parse(call.toolDetails as string);
      expect(composedAssets.some((asset) => asset.id === details.previewAssetId)).toBe(true);
    }

    // A step retry must not mint a second set of assets or a second revision: that is what the
    // (jobId, index) derived asset ids and the deterministic revision id are for.
    await db.update(generationJobs).set({ state: "running" }).where(eq(generationJobs.id, retry.jobId));
    const replay = await executeAiJobStep(retry.jobId);
    expect(replay.revisionId).toBe(retry.jobId);
    expect((await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId)))
      .filter((asset) => !asset.r2Key.includes("/tool-previews/"))).toHaveLength(partCount + 2);
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
    expect(stored.filter((asset) => !asset.r2Key.includes("/tool-previews/"))).toHaveLength(partCount + 2);
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
    // A fresh user retry must also reuse the stored clip and poster, not just a runtime replay.
    await failJobStep(confirmed.jobId, "Failure after video storage");
    const retry = await retryFailedChatTurn(db, "owner-v", sticker.stickerId, confirmed.messageId);
    expect((await stickerGenerationWorkflow(retry.jobId)).workflowStatus).toBe("succeeded");
    expect(videoRequests).toHaveLength(1);
    const retriedRevision = await db.select().from(stickerRevisions)
      .where(eq(stickerRevisions.id, retry.jobId)).then(firstRow);
    expect(StickerDocumentSchema.parse(retriedRevision!.documentJson).layers[0]).toMatchObject({
      assetId: clip!.id,
      posterAssetId: derivedAssetId(confirmed.jobId, 0),
    });
    expect((await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId)))
      .filter((asset) => !asset.r2Key.includes("/tool-previews/"))).toHaveLength(partCount + 2);

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
});
