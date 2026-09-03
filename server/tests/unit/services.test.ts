import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import stickerDocumentFixture from "@/fixtures/sticker-document-v1.json";
import { SHARING_APNG_DIMENSIONS, StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
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
  bindExports,
  createCandidateRevision,
  createChatTurn,
  createCleanupJob,
  createSticker,
  getSticker,
  importSticker,
  isActiveJobConstraint,
  listChatMessages,
  retryFailedChatTurn,
  revertRevision,
  saveEditedRevision,
  updateSticker,
} from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { cancelGenerationWorkflow } from "@/lib/services/workflows";
import { createTestDatabase } from "@/tests/helpers/database";
import { spliceApngControlChunks } from "@/tests/helpers/apng";

/** A transparent square with a painted block in one corner, which the rendition rules require. */
function transparentPng(dimension: number): Promise<Buffer> {
  const pixels = Buffer.alloc(dimension * dimension * 4, 0);
  for (let y = 8; y < 88; y += 1) {
    for (let x = 8; x < 48; x += 1) {
      const index = (y * dimension + x) * 4;
      pixels[index] = 200;
      pixels[index + 1] = 40;
      pixels[index + 2] = 90;
      pixels[index + 3] = 255;
    }
  }
  return sharp(pixels, { raw: { width: dimension, height: dimension, channels: 4 } }).png().toBuffer();
}

/**
 * Four frames at 150 ms — 0.6 s, which clears the half-second floor the rendition rules impose.
 *
 * sharp cannot write this format, so the animation lives entirely in spliced control chunks; see
 * `tests/helpers/apng.ts`. That is faithful to what completion inspects, which reads `acTL`/`fcTL`
 * rather than decoding frames.
 */
async function animatedApng(dimension: number): Promise<Buffer> {
  return spliceApngControlChunks(await transparentPng(dimension), [150, 150, 150, 150], 4, dimension);
}

/** The same corner block as raw RGBA, slid `offset` pixels right so frames can differ. */
function transparentPage(dimension: number, offset = 0): Buffer {
  const pixels = Buffer.alloc(dimension * dimension * 4, 0);
  for (let y = 8; y < 88; y += 1) {
    for (let x = 8 + offset; x < 48 + offset; x += 1) {
      const index = (y * dimension + x) * 4;
      pixels[index] = 200;
      pixels[index + 1] = 40;
      pixels[index + 2] = 90;
      pixels[index + 3] = 255;
    }
  }
  return pixels;
}

/**
 * The same four frames as an animated WebP, and written for real rather than spliced.
 *
 * libvips pages WebP natively in both directions, which is the reason this kind needs no
 * `readApngTiming` equivalent: sharp writes the frame delays into the file and `inspectImage` reads
 * them straight back out of `metadata.delay`.
 *
 * The block moves between frames because libwebp's animation encoder folds identical consecutive
 * frames into one — four copies of a still arrive as a single-frame file, which is a property of
 * the format rather than of anything under test.
 */
async function animatedWebp(dimension: number, frames = 4, delayMs = 150): Promise<Buffer> {
  const pages = Array.from({ length: frames }, (_, index) => transparentPage(dimension, index * 16));
  // Delays per frame rather than as a scalar: sharp's scalar `delay` lands on frame 0 alone and
  // leaves the rest at libwebp's 100 ms default, which quietly shortens the cycle being checked.
  const delays = Array.from({ length: frames }, () => delayMs);
  // `pages` and `pageHeight` are what make one tall buffer an animation. libvips takes both on raw
  // input; sharp's `CreateRaw` type does not list them, so this is bound to a variable rather than
  // written inline — an excess-property check on a fresh literal is the only thing in the way.
  const raw = {
    width: dimension,
    height: dimension * frames,
    channels: 4 as const,
    pages: frames,
    pageHeight: dimension,
  };
  return sharp(Buffer.concat(pages), { raw }).webp({ loop: 0, delay: delays }).toBuffer();
}

/** The static sticker's WebP: one frame, same rules minus the timing. */
async function stillWebp(dimension: number): Promise<Buffer> {
  return sharp(await transparentPng(dimension)).webp().toBuffer();
}

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

  it("renames only an owned live sticker", async () => {
    const sticker = await createSticker(db, "owner-a", {
      title: "First name", kind: "static", prompt: "Cloud", referenceAssetIds: [],
    });
    const renamed = await updateSticker(db, "owner-a", sticker.stickerId, { title: "Cloud Nine" });
    expect(renamed.title).toBe("Cloud Nine");

    await db.insert(users).values({ id: "owner-b", createdAt: new Date(), updatedAt: new Date() });
    await expect(updateSticker(db, "owner-b", sticker.stickerId, { title: "Not mine" }))
      .rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });

    await createCleanupJob(db, "owner-a", sticker.stickerId);
    await expect(updateSticker(db, "owner-a", sticker.stickerId, { title: "Too late" }))
      .rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });
  });

  it("imports a picture as a publishable static sticker, and only once", async () => {
    const assetId = crypto.randomUUID();
    await db.insert(assets).values({
      id: assetId,
      ownerId: "owner-a",
      kind: "reference",
      state: "ready",
      r2Key: objectKey("owner-a", assetId, "image/png"),
      mimeType: "image/png",
      byteSize: 4_096,
      width: 1024,
      height: 1024,
      sha256: "c".repeat(64),
      hasAlpha: true,
      createdAt: new Date(),
      readyAt: new Date(),
    });

    const imported = await importSticker(db, "owner-a", { title: "Concept", assetId });
    const detail = await getSticker(db, "owner-a", imported.stickerId);
    expect(detail.kind).toBe("static");
    // Active and accepted on arrival is the whole point: `bindExports` refuses anything else, and
    // publishing is what actually puts the sticker in the Messages pack.
    expect(detail.activeRevisionId).toBe(imported.revisionId);
    expect(detail.revisions.find((revision) => revision.id === imported.revisionId)?.candidateState).toBe("accepted");
    // No job — nothing was generated. One transcript entry, so opening the new project shows the
    // sticker rather than an empty room, and it is a `device_edit` marker rather than a user turn
    // the agent would answer.
    expect(await db.select().from(generationJobs).where(eq(generationJobs.stickerId, imported.stickerId))).toHaveLength(0);
    const transcript = await listChatMessages(db, "owner-a", imported.stickerId, { afterSequence: 0, limit: 10 });
    expect(transcript.data).toHaveLength(1);
    expect(transcript.data[0]).toMatchObject({ kind: "device_edit", revisionId: imported.revisionId });

    // The asset is now this sticker's, so a second import of the same upload would leave two
    // documents pointing at one piece of artwork.
    await expect(importSticker(db, "owner-a", { title: "Concept again", assetId }))
      .rejects.toMatchObject({ code: "REFERENCE_ALREADY_ATTACHED" });
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

  it("records which turns quick mode asked for, including their retries", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Wink", kind: "static", prompt: "A winking cat", referenceAssetIds: [] });
    const quick = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "A winking cat",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
      quick: true,
    });
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, quick.jobId)).then(firstRow))?.quick).toBe(true);

    // A retry is the same turn asked again, so it has to reach the same image model. Nothing on the
    // retry request says which surface started it — the extension's Retry button and the app's are
    // the same call — so the flag can only come from the job being retried.
    await db.update(generationJobs).set({ state: "failed", completedAt: new Date() }).where(eq(generationJobs.id, quick.jobId));
    await db.update(chatMessages).set({ status: "failed" }).where(eq(chatMessages.id, quick.messageId));
    const retry = await retryFailedChatTurn(db, "owner-a", sticker.stickerId, quick.messageId);
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, retry.jobId)).then(firstRow))?.quick).toBe(true);
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() }).where(eq(generationJobs.id, retry.jobId));

    // Every other client omits the flag, and an omission is the slow, transparent model.
    const ordinary = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Make it wave instead",
      intent: "edit",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, ordinary.jobId)).then(firstRow))?.quick).toBe(false);
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
    expect((await db.select().from(idempotencyKeys).where(eq(idempotencyKeys.key, ambiguous.key)).then(firstRow))?.responseStatus).toBeNull();
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
    expect(await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).then(firstRow)).toMatchObject({
      state: "cancelled",
      errorCode: "USER_CANCELLED",
    });
    expect(await db.select().from(chatMessages).where(eq(chatMessages.id, turn.messageId)).then(firstRow)).toMatchObject({ status: "complete" });
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
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
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
    const pending = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
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
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "SYSTEM_STICKER_REQUIRES_TRANSPARENCY" });
  });

  it("allows only Apple system sticker square presets", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 320, height: 320, channels: 4, background: { r: 10, g: 20, b: 30, alpha: 0.5 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", { kind: "system", mimeType: "image/png", byteSize: png.byteLength, filename: "wrong-size.png" });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_SYSTEM_STICKER_SIZE" });
  });

  /**
   * A sharing rendition whose only fixed size was 1024 could not be published at all: the GIF this
   * replaced wrote every frame at full size, so a long animation declared a `byteSize` past the
   * upload ceiling and died on a 400 before a single byte was presigned. Stepping the export down
   * its size ladder is the fix, and it only works if completion admits the rungs it lands on.
   */
  it("accepts a sharing APNG stepped down to fit the upload ceiling", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const apng = await animatedApng(512);
    const created = await createUpload(db, "owner-a", {
      kind: "apng",
      mimeType: "image/png",
      byteSize: apng.byteLength,
      filename: "sharing-512.png",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: apng, contentType: "image/png" });
    expect(await completeUpload(db, "owner-a", row!.id))
      .toMatchObject({ state: "ready", width: 512, height: 512, frameCount: 4 });
  });

  it("rejects a sharing APNG at a size the export ladder never produces", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    expect(SHARING_APNG_DIMENSIONS).not.toContain(640);
    const apng = await animatedApng(640);
    const created = await createUpload(db, "owner-a", {
      kind: "apng",
      mimeType: "image/png",
      byteSize: apng.byteLength,
      filename: "sharing-640.png",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: apng, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_APNG_EXPORT" });
  });

  /**
   * A still PNG under the sharing kind is the shape of a client that lost its animation somewhere
   * between rendering and upload. Nothing about the mime type can catch it — an APNG *is* a PNG —
   * so the frame count read back off the chunks is the only thing standing between a frozen sticker
   * and a published library.
   */
  it("rejects a still PNG published as the sharing rendition", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const still = await transparentPng(512);
    const created = await createUpload(db, "owner-a", {
      kind: "apng",
      mimeType: "image/png",
      byteSize: still.byteLength,
      filename: "sharing-still.png",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: still, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_APNG_EXPORT" });
  });

  /**
   * The two smaller sends. Unlike the sharing rendition these admit a still — a static sticker has
   * a Medium and a Small too — and unlike the system sticker they are under no byte ceiling, which
   * is the whole reason they exist: they carry the document's own frame rate rather than whatever
   * the 500 KB ladder could afford.
   */
  it("accepts animated and still attachment renditions at their two sizes", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    for (const [dimension, bytes] of [
      [408, await animatedApng(408)],
      [300, await transparentPng(300)],
    ] as const) {
      const created = await createUpload(db, "owner-a", {
        kind: "attachment",
        mimeType: "image/png",
        byteSize: bytes.byteLength,
        filename: `attachment-${dimension}.png`,
      });
      const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
      await store.put(row!.r2Key, { bytes, contentType: "image/png" });
      expect(await completeUpload(db, "owner-a", row!.id))
        .toMatchObject({ state: "ready", width: dimension, height: dimension });
    }
  });

  /**
   * 618 is Large, and Large is the sharing rendition — it has a column of its own and arrives under
   * `apng` or `master`. One under this kind is a client that filled the wrong slot, which would
   * hand someone the same file whichever size they picked.
   */
  it("rejects an attachment rendition at the size Large already occupies", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const apng = await animatedApng(618);
    const created = await createUpload(db, "owner-a", {
      kind: "attachment",
      mimeType: "image/png",
      byteSize: apng.byteLength,
      filename: "attachment-618.png",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: apng, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_ATTACHMENT_EXPORT" });
  });

  /**
   * The WebP copy of the sharing rendition. It admits a still — a static sticker has one too — and
   * it is held to the sharing rendition's pixel ladder rather than the attachment sizes, because it
   * is a copy of Large rather than of the two smaller sends.
   */
  it("accepts animated and still WebP sharing renditions across the sharing ladder", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    for (const [dimension, bytes, frameCount] of [
      [618, await animatedWebp(618), 4],
      [1024, await stillWebp(1024), 1],
    ] as const) {
      const created = await createUpload(db, "owner-a", {
        kind: "webp",
        mimeType: "image/webp",
        byteSize: bytes.byteLength,
        filename: `sharing-${dimension}.webp`,
      });
      const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
      await store.put(row!.r2Key, { bytes, contentType: "image/webp" });
      expect(await completeUpload(db, "owner-a", row!.id))
        .toMatchObject({ state: "ready", width: dimension, height: dimension, frameCount });
    }
  });

  it("rejects a WebP rendition at a size the sharing ladder never produces", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    expect(SHARING_APNG_DIMENSIONS).not.toContain(640);
    const bytes = await animatedWebp(640);
    const created = await createUpload(db, "owner-a", {
      kind: "webp",
      mimeType: "image/webp",
      byteSize: bytes.byteLength,
      filename: "sharing-640.webp",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes, contentType: "image/webp" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_WEBP_EXPORT" });
  });

  /**
   * A sticker is artwork cut out of its background, so an opaque rendition is one that was
   * flattened somewhere in the encode — it would arrive in the transcript on a white square.
   */
  it("rejects an opaque WebP rendition", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const bytes = await sharp({
      create: { width: 618, height: 618, channels: 4, background: { r: 12, g: 34, b: 56, alpha: 1 } },
    }).webp().toBuffer();
    const created = await createUpload(db, "owner-a", {
      kind: "webp",
      mimeType: "image/webp",
      byteSize: bytes.byteLength,
      filename: "opaque.webp",
    });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes, contentType: "image/webp" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "INVALID_WEBP_EXPORT" });
  });

  it("rejects a fully transparent empty mask", async () => {
    const store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    const png = await sharp({ create: { width: 256, height: 256, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).png().toBuffer();
    const created = await createUpload(db, "owner-a", { kind: "mask", mimeType: "image/png", byteSize: png.byteLength, filename: "empty-mask.png" });
    const row = await db.select().from(assets).where(eq(assets.id, created.asset.id)).then(firstRow);
    await store.put(row!.r2Key, { bytes: png, contentType: "image/png" });
    await expect(completeUpload(db, "owner-a", row!.id)).rejects.toMatchObject({ code: "MASK_REQUIRES_ALPHA" });
  });

  /**
   * The MP4 is the one rendition a publish may leave out: nothing on the platform reads it, and
   * encoding one is the slowest thing an export does, so a sticker-only export never renders it.
   */
  it("publishes an animated sticker that has no video, but not one that has no GIF", async () => {
    const sticker = await createSticker(db, "owner-a", {
      title: "Spark", kind: "animated", prompt: "Sparkles", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Sparkles", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
      .where(eq(generationJobs.id, turn.jobId));
    // The fixture's particle layer, which is keyframed and draws no image assets of its own.
    const document = StickerDocumentSchema.parse({
      ...stickerDocumentFixture,
      durationSeconds: 1,
      fps: 10,
      loop: "loop",
      layers: [stickerDocumentFixture.layers[1]],
    });
    const revisionId = await createCandidateRevision(db, {
      ownerId: "owner-a", stickerId: sticker.stickerId, sourceMessageId: turn.messageId, document,
    });
    await acceptRevision(db, "owner-a", sticker.stickerId, revisionId);

    // A 1 s cycle at 10 FPS is 10 frames, held 0.6 s longer on the last of them before repeating.
    const renditionIds = {
      apng: crypto.randomUUID(),
      system: crypto.randomUUID(),
      medium: crypto.randomUUID(),
      small: crypto.randomUUID(),
      webp: crypto.randomUUID(),
      stillWebp: crypto.randomUUID(),
    };
    await db.insert(assets).values([
      { id: renditionIds.apng, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "apng", state: "ready", r2Key: objectKey("owner-a", renditionIds.apng, "image/png"), mimeType: "image/png", byteSize: 120_000, width: 618, height: 618, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", renditionIds.system, "image/png"), mimeType: "image/png", byteSize: 400_000, width: 408, height: 408, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "b".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.medium, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "attachment", state: "ready", r2Key: objectKey("owner-a", renditionIds.medium, "image/png"), mimeType: "image/png", byteSize: 90_000, width: 408, height: 408, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "c".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.small, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "attachment", state: "ready", r2Key: objectKey("owner-a", renditionIds.small, "image/png"), mimeType: "image/png", byteSize: 50_000, width: 300, height: 300, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "d".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      // A twentieth of the APNG at the same size and grid, which is the entire reason it exists.
      { id: renditionIds.webp, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "webp", state: "ready", r2Key: objectKey("owner-a", renditionIds.webp, "image/webp"), mimeType: "image/webp", byteSize: 6_000, width: 618, height: 618, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "e".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: renditionIds.stillWebp, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "webp", state: "ready", r2Key: objectKey("owner-a", renditionIds.stillWebp, "image/webp"), mimeType: "image/webp", byteSize: 3_000, width: 618, height: 618, frameCount: 1, durationSeconds: 0, fps: 0, sha256: "f".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    ]);

    const publishRequest = {
      revisionId,
      apngAssetId: renditionIds.apng,
      systemAssetId: renditionIds.system,
      attachmentMediumAssetId: renditionIds.medium,
      attachmentSmallAssetId: renditionIds.small,
      mp4Background: { type: "solid" as const, color: "#FFFFFF" },
    };
    await expect(bindExports(db, "owner-a", sticker.stickerId, { ...publishRequest, apngAssetId: undefined }, crypto.randomUUID()))
      .rejects.toMatchObject({ code: "ANIMATED_EXPORTS_REQUIRED" });
    // Swapped: Medium pointed at the 300 px file. Nothing about the assets themselves is wrong, so
    // the pairing is the only thing that can catch it — and left uncaught it hands someone Small
    // whichever of the two sizes they ask for.
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...publishRequest,
      attachmentMediumAssetId: renditionIds.small,
      attachmentSmallAssetId: renditionIds.medium,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "INVALID_ATTACHMENT_SIZE" });
    // The sharing rendition is Large and lives in its own column; naming it here is a client that
    // would publish the same file under two sizes.
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...publishRequest,
      attachmentMediumAssetId: renditionIds.apng,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "INVALID_ATTACHMENT_EXPORT" });

    // Optional, but not unchecked. A still WebP under an animated sticker is the shape of a client
    // whose encoder dropped the animation, and publishing it would make `.image` mode the one
    // surface where this sticker does not move.
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...publishRequest,
      webpAssetId: renditionIds.stillWebp,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "WEBP_RENDITION_MISMATCH" });
    // The right container under the wrong kind. `apng` is a rendition of the same frames, so
    // nothing but the kind separates it from the file this column is for.
    await expect(bindExports(db, "owner-a", sticker.stickerId, {
      ...publishRequest,
      webpAssetId: renditionIds.apng,
    }, crypto.randomUUID())).rejects.toMatchObject({ code: "INVALID_WEBP_EXPORT" });

    const publishedRevisionId = crypto.randomUUID();
    const published = await bindExports(db, "owner-a", sticker.stickerId, { ...publishRequest, webpAssetId: renditionIds.webp }, publishedRevisionId);
    expect(published.status).toBe("published");
    const publishedRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).then(firstRow);
    expect(publishedRevision?.mp4AssetId).toBeNull();
    expect(publishedRevision?.apngAssetId).toBe(renditionIds.apng);
    expect(publishedRevision?.attachmentMediumAssetId).toBe(renditionIds.medium);
    expect(publishedRevision?.attachmentSmallAssetId).toBe(renditionIds.small);
    expect(publishedRevision?.webpAssetId).toBe(renditionIds.webp);
    // The extension reads it off the summary, beside — never instead of — the APNG it falls back to.
    const summary = await getSticker(db, "owner-a", sticker.stickerId);
    expect(summary.webpAsset?.id).toBe(renditionIds.webp);
    expect(summary.previewAsset?.id).toBe(renditionIds.apng);
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.status).toBe("published");
  });

  /**
   * The client that predates attachment renditions. Its stickers simply offer one size in
   * WinkySticker; a publish that refused them would break every build already in the field.
   */
  it("publishes an animated sticker with no attachment renditions at all", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Sparkles", kind: "animated", prompt: "Sparkles", referenceAssetIds: [] });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Sparkles", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
      .where(eq(generationJobs.id, turn.jobId));
    const document = StickerDocumentSchema.parse({
      ...stickerDocumentFixture,
      durationSeconds: 1,
      fps: 10,
      loop: "loop",
      layers: [stickerDocumentFixture.layers[1]],
    });
    const revisionId = await createCandidateRevision(db, {
      ownerId: "owner-a", stickerId: sticker.stickerId, sourceMessageId: turn.messageId, document,
    });
    await acceptRevision(db, "owner-a", sticker.stickerId, revisionId);

    const ids = { apng: crypto.randomUUID(), system: crypto.randomUUID() };
    await db.insert(assets).values([
      { id: ids.apng, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "apng", state: "ready", r2Key: objectKey("owner-a", ids.apng, "image/png"), mimeType: "image/png", byteSize: 120_000, width: 1024, height: 1024, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
      { id: ids.system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", ids.system, "image/png"), mimeType: "image/png", byteSize: 400_000, width: 408, height: 408, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "b".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    ]);

    const publishedRevisionId = crypto.randomUUID();
    await bindExports(db, "owner-a", sticker.stickerId, {
      revisionId,
      apngAssetId: ids.apng,
      systemAssetId: ids.system,
      mp4Background: { type: "solid" as const, color: "#FFFFFF" },
    }, publishedRevisionId);
    const publishedRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).then(firstRow);
    expect(publishedRevision?.attachmentMediumAssetId).toBeNull();
    expect(publishedRevision?.attachmentSmallAssetId).toBeNull();
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
      const row = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, result.revisionId)).then(firstRow);
      expect(row?.candidateState).toBe("accepted");
      expect(row?.decidedAt).toBeTruthy();
      expect((row?.documentJson as typeof document).layers[0].name).toBe("Edited Dot");
      const sticker = await db.select().from(stickers).where(eq(stickers.id, stickerId)).then(firstRow);
      expect(sticker?.activeRevisionId).toBe(result.revisionId);
    });

    it("marks the edit in the transcript as a device edit rather than a typed turn", async () => {
      const { stickerId, parentId, document } = await setup();
      const result = await saveEditedRevision(db, "owner-a", stickerId, {
        parentRevisionId: parentId, document, note: "Nudged the dot",
      });
      const row = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, result.revisionId)).then(firstRow);
      expect(row?.sourceMessageId).toBeTruthy();
      const message = await db.select().from(chatMessages).where(eq(chatMessages.id, row!.sourceMessageId!)).then(firstRow);
      expect(message).toMatchObject({ role: "user", kind: "device_edit", content: "Nudged the dot", revisionId: result.revisionId });
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
      const candidate = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, candidateId)).then(firstRow);
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

  /**
   * `isActiveJobConstraint` turns one specific database error into a 409 in five call sites, and it
   * recognises it by the index's name appearing in the message. That name is the driver's wording,
   * not ours — libSQL wrote "UNIQUE constraint failed: generation_jobs.sticker_id" and Postgres
   * writes the constraint name, wrapped a layer deep inside drizzle's own error. Nothing else here
   * would notice if a driver change turned every duplicate-job request into a 500.
   */
  it("recognises the active-job index firing through the driver's own error", async () => {
    const now = new Date();
    await db.insert(users).values({ id: "job-owner", createdAt: now, updatedAt: now });
    await db.insert(stickers).values({
      id: "job-sticker", ownerId: "job-owner", title: "Busy", kind: "static", createdAt: now, updatedAt: now,
    });
    const job = (id: string) => ({
      id, ownerId: "job-owner", stickerId: "job-sticker", kind: "image" as const,
      state: "queued" as const, createdAt: now, updatedAt: now,
    });
    await db.insert(generationJobs).values(job("job-first"));

    const conflict = await db.insert(generationJobs).values(job("job-second")).then(
      () => undefined,
      (error: unknown) => error,
    );
    expect(conflict).toBeDefined();
    expect(isActiveJobConstraint(conflict)).toBe(true);
    // An unrelated failure must not be read as a queue conflict and answered with a 409.
    expect(isActiveJobConstraint(new Error("connection terminated unexpectedly"))).toBe(false);
  });

});
