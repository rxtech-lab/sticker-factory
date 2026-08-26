import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import type { Database } from "@/lib/db/client";
import {
  assets,
  chatMessages,
  generationJobs,
  idempotencyKeys,
  stickerRevisions,
  stickers,
  users,
} from "@/lib/db/schema";
import { createAssetDownload, createAssetPreview, createUpload, completeUpload } from "@/lib/services/assets";
import { appendGenerationEvent, listGenerationEvents } from "@/lib/services/events";
import { executeIdempotent } from "@/lib/services/idempotency";
import {
  acceptRevision,
  createCandidateRevision,
  createChatTurn,
  createCleanupJob,
  createSticker,
  listChatMessages,
  retryFailedChatTurn,
  revertRevision,
  saveEditedRevision,
} from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { cancelGenerationWorkflow } from "@/lib/services/workflows";
import { createTestDatabase } from "@/tests/helpers/database";

describe("Sticker Factory services", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await db.insert(users).values({ id: "owner-a", email: "a@example.test", createdAt: new Date(), updatedAt: new Date() });
  });

  afterEach(async () => {
    setObjectStoreForTests(undefined);
    await close();
  });

  it("orders persistent chat, enforces one active turn, and bounds retries", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Wave", kind: "static", prompt: "A waving cat", referenceAssetIds: [] });
    const first = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "A waving cat",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await expect(createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Try blue",
      intent: "edit",
      attachments: [],
      imagePlacement: "replace",
    })).rejects.toMatchObject({ code: "AI_TURN_IN_PROGRESS" });

    await db.update(generationJobs).set({ state: "failed", completedAt: new Date() }).where(eq(generationJobs.id, first.jobId));
    await db.update(chatMessages).set({ status: "failed" }).where(eq(chatMessages.id, first.messageId));
    const retry = await retryFailedChatTurn(db, "owner-a", sticker.stickerId, first.messageId);
    expect(retry.messageId).toBe(first.messageId);
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() }).where(eq(generationJobs.id, retry.jobId));

    const second = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "What motion would work?",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() }).where(eq(generationJobs.id, second.jobId));
    const page = await listChatMessages(db, "owner-a", sticker.stickerId, { afterSequence: 1, limit: 10 });
    expect(page.data.map((message) => message.content)).toEqual(["What motion would work?"]);
    const fromStart = await listChatMessages(db, "owner-a", sticker.stickerId, { afterSequence: 0, limit: 10 });
    expect(fromStart.data.map((message) => message.sequence)).toEqual([1, 2]);
  });

  it("keeps revision core immutable while accept and revert create durable history", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Cloud", kind: "static", prompt: "Cloud", referenceAssetIds: [] });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Cloud",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() }).where(eq(generationJobs.id, turn.jobId));
    const assetId = crypto.randomUUID();
    await db.insert(assets).values({
      id: assetId,
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      kind: "master",
      state: "ready",
      r2Key: objectKey("owner-a", assetId, "image/png"),
      mimeType: "image/png",
      byteSize: 10,
      width: 1024,
      height: 1024,
      sha256: "a".repeat(64),
      hasAlpha: true,
      createdAt: new Date(),
      readyAt: new Date(),
    });
    // Parsed rather than built as a literal so schema defaults (anchor, animations) fill in and
    // the value is exactly the shape the service expects.
    const document = StickerDocumentSchema.parse({
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers: [{ id: "hero", name: "Hero", hidden: false, type: "image", assetId, contentMode: "fit" }],
    });
    // Narrowed out of the layer union so spreading it keeps producing an image layer.
    const hero = document.layers[0];
    if (hero.type !== "image") throw new Error("expected an image layer");
    await expect(createCandidateRevision(db, {
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      sourceMessageId: turn.messageId,
      document: { ...document, layers: [{ ...hero, assetId: crypto.randomUUID() }] },
    })).rejects.toMatchObject({ code: "INVALID_ASSET_REFERENCE" });
    await db.insert(users).values({ id: "owner-b", createdAt: new Date(), updatedAt: new Date() });
    const foreignAssetId = crypto.randomUUID();
    await db.insert(assets).values({
      id: foreignAssetId,
      ownerId: "owner-b",
      stickerId: sticker.stickerId,
      kind: "master",
      state: "ready",
      r2Key: objectKey("owner-b", foreignAssetId, "image/png"),
      mimeType: "image/png",
      byteSize: 10,
      width: 1024,
      height: 1024,
      sha256: "b".repeat(64),
      hasAlpha: true,
      createdAt: new Date(),
      readyAt: new Date(),
    });
    await expect(createCandidateRevision(db, {
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      sourceMessageId: turn.messageId,
      document: { ...document, layers: [{ ...hero, assetId: foreignAssetId }] },
    })).rejects.toMatchObject({ code: "INVALID_ASSET_REFERENCE" });
    const revisionId = await createCandidateRevision(db, {
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      sourceMessageId: turn.messageId,
      document,
      masterAssetId: assetId,
      previewAssetId: assetId,
    });
    await acceptRevision(db, "owner-a", sticker.stickerId, revisionId);
    await expect(acceptRevision(db, "owner-a", sticker.stickerId, revisionId)).resolves.toMatchObject({ activeRevisionId: revisionId });
    const decisionId = crypto.randomUUID();
    const reverted = await revertRevision(db, "owner-a", sticker.stickerId, revisionId, decisionId);
    const replayed = await revertRevision(db, "owner-a", sticker.stickerId, revisionId, decisionId);
    expect(reverted.revisionId).not.toBe(revisionId);
    expect(replayed.revisionId).toBe(reverted.revisionId);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId))).toHaveLength(2);
    await expect(db.update(stickerRevisions).set({ documentJson: { ...document, layers: [] } }).where(eq(stickerRevisions.id, revisionId)))
      .rejects.toMatchObject({ cause: { message: expect.stringMatching(/immutable/) } });
    await expect(db.update(stickerRevisions).set({ pngAssetId: assetId }).where(eq(stickerRevisions.id, revisionId)))
      .rejects.toMatchObject({ cause: { message: expect.stringMatching(/immutable/) } });
  });

  it("replays monotonic events and idempotent responses", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Event", kind: "static", prompt: "Event", referenceAssetIds: [] });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, { text: "Event", intent: "generate", attachments: [], imagePlacement: "replace" });
    const first = await appendGenerationEvent(db, turn.jobId, "owner-a", "progress", { progress: 0.5 });
    const second = await appendGenerationEvent(db, turn.jobId, "owner-a", "completed", { ok: true });
    const replay = await listGenerationEvents(db, "owner-a", turn.jobId, first.id);
    expect(replay.events.map((event) => event.id)).toEqual([second.id]);

    let calls = 0;
    const options = { ownerId: "owner-a", operation: "test", key: "test-key-123", request: { value: 1 } };
    const one = await executeIdempotent(db, options, async () => ({ status: 201, body: { calls: ++calls } }));
    const two = await executeIdempotent(db, options, async () => ({ status: 201, body: { calls: ++calls } }));
    expect(one.replayed).toBe(false);
    expect(two).toMatchObject({ replayed: true, body: { calls: 1 } });

    const ambiguous = { ownerId: "owner-a", operation: "ambiguous", key: "ambiguous-key", request: { value: 2 } };
    await expect(executeIdempotent(db, ambiguous, async () => { throw new Error("connection lost after dispatch"); })).rejects.toThrow(/connection lost/);
    expect((await db.select().from(idempotencyKeys).where(eq(idempotencyKeys.key, ambiguous.key)).get())?.responseStatus).toBeNull();
    await expect(executeIdempotent(db, ambiguous, async () => ({ status: 200, body: { ok: true } })))
      .rejects.toMatchObject({ code: "REQUEST_IN_PROGRESS" });
    await db.update(idempotencyKeys).set({ expiresAt: new Date(Date.now() - 1) }).where(eq(idempotencyKeys.key, ambiguous.key));
    await expect(executeIdempotent(db, ambiguous, async () => ({ status: 200, body: { ok: true } })))
      .resolves.toMatchObject({ replayed: false, body: { ok: true } });
  });

  it("stops an active chat turn and leaves the transcript ready for the next message", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Stop", kind: "static", prompt: "Stop", referenceAssetIds: [] });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Make it blue",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });

    await expect(cancelGenerationWorkflow(db, "owner-a", turn.jobId)).resolves.toEqual({ jobId: turn.jobId, state: "cancelled" });
    expect(await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).get()).toMatchObject({
      state: "cancelled",
      errorCode: "USER_CANCELLED",
    });
    expect(await db.select().from(chatMessages).where(eq(chatMessages.id, turn.messageId)).get()).toMatchObject({ status: "complete" });
    const terminal = (await listGenerationEvents(db, "owner-a", turn.jobId)).events.at(-1);
    expect(terminal).toMatchObject({ type: "completed", dataJson: { cancelled: true, message: "Stopped" } });
    await expect(createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Try red instead",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    })).resolves.toMatchObject({ sticker: { id: sticker.stickerId } });
  });

  it("verifies private R2 object content before completing a system upload", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 408, height: 408, channels: 4, background: { r: 255, g: 100, b: 150, alpha: 0.5 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", {
      kind: "system",
      mimeType: "image/png",
      byteSize: png.byteLength,
      filename: "system.png",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).get();
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    const completed = await completeUpload(db, "owner-a", row!.id);
    expect(completed).toMatchObject({ state: "ready", width: 408, height: 408, hasAlpha: true });
    expect((await createAssetDownload(db, "owner-a", row!.id)).url).toContain("disposition=attachment%3B");
    expect((await createAssetPreview(db, "owner-a", row!.id)).url).toContain("mode=inline");
  });

  it("rejects upload binding and completion once project deletion begins", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const sticker = await createSticker(db, "owner-a", { title: "Delete", kind: "static", prompt: "Delete", referenceAssetIds: [] });
    const png = await sharp({ create: { width: 408, height: 408, channels: 4, background: { r: 10, g: 20, b: 30, alpha: 0.5 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", {
      stickerId: sticker.stickerId,
      kind: "system",
      mimeType: "image/png",
      byteSize: png.byteLength,
      filename: "late.png",
    });
    const pending = await db.select().from(assets).where(eq(assets.id, created.asset.id)).get();
    await store.put(pending!.r2Key, { bytes: png, contentType: "image/png" });
    await createCleanupJob(db, "owner-a", sticker.stickerId);
    await expect(completeUpload(db, "owner-a", pending!.id)).rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });
    await expect(db.insert(assets).values({
      id: crypto.randomUUID(),
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      kind: "reference",
      state: "pending",
      r2Key: `private/late/${crypto.randomUUID()}.png`,
      mimeType: "image/png",
      createdAt: new Date(),
    })).rejects.toMatchObject({ cause: { message: expect.stringMatching(/deleting sticker/) } });
  });

  it("rejects opaque system sticker renditions", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 300, height: 300, channels: 4, background: { r: 10, g: 20, b: 30, alpha: 1 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", { kind: "system", mimeType: "image/png", byteSize: png.byteLength, filename: "opaque.png" });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).get();
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "SYSTEM_STICKER_REQUIRES_TRANSPARENCY" });
  });

  it("allows only Apple system sticker square presets", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 320, height: 320, channels: 4, background: { r: 10, g: 20, b: 30, alpha: 0.5 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", { kind: "system", mimeType: "image/png", byteSize: png.byteLength, filename: "wrong-size.png" });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).get();
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_SYSTEM_STICKER_SIZE" });
  });

  it("rejects a fully transparent empty mask", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 256, height: 256, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", { kind: "mask", mimeType: "image/png", byteSize: png.byteLength, filename: "empty-mask.png" });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).get();
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "MASK_REQUIRES_ALPHA" });
  });

  /**
   * A hand edit saved from the client. Unlike a generated candidate there is nothing to review, so
   * the revision arrives already accepted and immediately becomes the sticker's active one.
   */
  describe("saveEditedRevision", () => {
    async function setup() {
      const sticker = await createSticker(db, "owner-a", { title: "Cloud", kind: "static", prompt: "Cloud", referenceAssetIds: [] });
      const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
        text: "Cloud", intent: "generate", attachments: [], imagePlacement: "replace",
      });
      await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
        .where(eq(generationJobs.id, turn.jobId));

      const document = StickerDocumentSchema.parse({
        version: 2,
        canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
        kind: "static",
        durationSeconds: 0,
        fps: 0,
        loop: "once",
        mp4Background: { type: "solid", color: "#FFFFFF" },
        layers: [{ id: "dot", name: "Dot", type: "shape", shape: { kind: "circle" }, fill: { type: "solid", color: "#FF0000" } }],
      });
      const parentId = await createCandidateRevision(db, {
        ownerId: "owner-a",
        stickerId: sticker.stickerId,
        sourceMessageId: turn.messageId,
        document,
      });
      await acceptRevision(db, "owner-a", sticker.stickerId, parentId);
      return { stickerId: sticker.stickerId, parentId, document };
    }

    it("inserts an accepted revision and makes it active", async () => {
      const { stickerId, parentId, document } = await setup();
      const edited = structuredClone(document);
      edited.layers[0].name = "Edited Dot";

      const result = await saveEditedRevision(db, "owner-a", stickerId, {
        parentRevisionId: parentId,
        document: edited,
      }, "11111111-1111-4111-8111-111111111111");

      expect(result).toMatchObject({ candidateState: "accepted", parentRevisionId: parentId });
      const row = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, result.revisionId)).get();
      expect(row?.candidateState).toBe("accepted");
      expect(row?.decidedAt).toBeTruthy();
      expect((row?.documentJson as typeof document).layers[0].name).toBe("Edited Dot");
      const sticker = await db.select().from(stickers).where(eq(stickers.id, stickerId)).get();
      expect(sticker?.activeRevisionId).toBe(result.revisionId);
    });

    it("shows the edit in the transcript so the chat needs no special case for it", async () => {
      const { stickerId, parentId, document } = await setup();
      const result = await saveEditedRevision(db, "owner-a", stickerId, {
        parentRevisionId: parentId, document, note: "Nudged the dot",
      });
      const row = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, result.revisionId)).get();
      expect(row?.sourceMessageId).toBeTruthy();
      const message = await db.select().from(chatMessages).where(eq(chatMessages.id, row!.sourceMessageId!)).get();
      expect(message).toMatchObject({ role: "user", kind: "animation", content: "Nudged the dot", revisionId: result.revisionId });
    });

    /** Retrying a dropped response must replay the same row, not fork the chain. */
    it("replays a deterministic id instead of creating a second revision", async () => {
      const { stickerId, parentId, document } = await setup();
      const id = "22222222-2222-4222-8222-222222222222";
      const first = await saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document }, id);
      const second = await saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document }, id);
      expect(second.revisionId).toBe(first.revisionId);
      const rows = await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, stickerId));
      expect(rows).toHaveLength(2);
    });

    it("retires a candidate the edit has moved past", async () => {
      const { stickerId, parentId, document } = await setup();
      const turn = await createChatTurn(db, "owner-a", stickerId, {
        text: "Again", intent: "generate", attachments: [], imagePlacement: "replace",
      });
      await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
        .where(eq(generationJobs.id, turn.jobId));
      const candidateId = await createCandidateRevision(db, {
        ownerId: "owner-a", stickerId, sourceMessageId: turn.messageId, document,
      });

      await saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document });
      const candidate = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, candidateId)).get();
      expect(candidate?.candidateState).toBe("superseded");
    });

    /** Nothing in the schema serialises an edit against a running generation. */
    it("refuses to save while a generation is in flight", async () => {
      const { stickerId, parentId, document } = await setup();
      await createChatTurn(db, "owner-a", stickerId, {
        text: "Busy", intent: "generate", attachments: [], imagePlacement: "replace",
      });
      await expect(saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document }))
        .rejects.toMatchObject({ code: "STICKER_OPERATION_IN_PROGRESS" });
    });

    it("rejects a parent that belongs to another sticker or was already turned down", async () => {
      const { stickerId, parentId, document } = await setup();
      await expect(saveEditedRevision(db, "owner-a", stickerId, {
        parentRevisionId: crypto.randomUUID(), document,
      })).rejects.toMatchObject({ code: "INVALID_PARENT_REVISION" });

      await db.update(stickerRevisions).set({ candidateState: "rejected" }).where(eq(stickerRevisions.id, parentId));
      await expect(saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document }))
        .rejects.toMatchObject({ code: "INVALID_PARENT_REVISION" });
    });

    it("rejects a document whose kind contradicts the project", async () => {
      const { stickerId, parentId } = await setup();
      const animated = StickerDocumentSchema.parse({
        version: 2,
        canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
        kind: "animated",
        durationSeconds: 2,
        fps: 30,
        loop: "loop",
        mp4Background: { type: "solid", color: "#FFFFFF" },
        layers: [],
      });
      await expect(saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document: animated }))
        .rejects.toMatchObject({ code: "REVISION_KIND_MISMATCH" });
    });

    it("rejects a document naming an asset the owner does not have", async () => {
      const { stickerId, parentId, document } = await setup();
      const withImage = StickerDocumentSchema.parse({
        ...structuredClone(document),
        layers: [{ id: "hero", name: "Hero", type: "image", assetId: crypto.randomUUID(), contentMode: "fit" }],
      });
      await expect(saveEditedRevision(db, "owner-a", stickerId, { parentRevisionId: parentId, document: withImage }))
        .rejects.toMatchObject({ code: "INVALID_ASSET_REFERENCE" });
    });

    it("is invisible to another owner", async () => {
      const { stickerId, parentId, document } = await setup();
      await db.insert(users).values({ id: "owner-b", createdAt: new Date(), updatedAt: new Date() });
      await expect(saveEditedRevision(db, "owner-b", stickerId, { parentRevisionId: parentId, document }))
        .rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });
    });
  });

});
