import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import stickerDocumentFixture from "@/fixtures/sticker-document-v1.json";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, setDatabaseForTests, type Database } from "@/lib/db/client";
import { assets, generationEvents, generationJobs, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { publishExports } from "@/lib/services/export-publish";
import {
  acceptRevision,
  createCandidateRevision,
  createChatTurn,
  createExportJob,
  createSticker,
} from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";

/**
 * A seam for the one branch that cannot be reached by asking for something invalid: a bind that
 * fails on something other than a verdict about the request.
 */
const { bindFailure } = vi.hoisted(() => ({ bindFailure: { error: null as unknown } }));
vi.mock("@/lib/services/sticker-exports", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/services/sticker-exports")>();
  return {
    ...actual,
    bindExports: async (...args: Parameters<typeof actual.bindExports>) => {
      if (bindFailure.error) throw bindFailure.error;
      return actual.bindExports(...args);
    },
  };
});

let db: Database;
let close: () => Promise<void>;

beforeEach(async () => {
  ({ db, close } = await createTestDatabase());
  // The job lifecycle resolves its own handle rather than taking one, because a workflow step has
  // no caller to be handed one by.
  setDatabaseForTests(db);
  setObjectStoreForTests(new MemoryObjectStore());
  await db.insert(users).values({ id: "owner-a", createdAt: new Date(), updatedAt: new Date() });
});

afterEach(async () => {
  await close();
  setDatabaseForTests(undefined);
  setObjectStoreForTests(undefined);
  bindFailure.error = null;
});

/** An accepted animated revision with its renditions already uploaded and verified. */
async function readyToPublish() {
  const sticker = await createSticker(db, "owner-a", {
    title: "Spark", kind: "animated", prompt: "Sparkles", referenceAssetIds: [],
  });
  const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
    text: "Sparkles", intent: "generate", attachments: [], imagePlacement: "replace",
  });
  await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
    .where(eq(generationJobs.id, turn.jobId));
  // The fixture's particle layer: keyframed, and drawing no image assets of its own.
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
  const apng = crypto.randomUUID();
  const system = crypto.randomUUID();
  await db.insert(assets).values([
    { id: apng, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "apng", state: "ready", r2Key: objectKey("owner-a", apng, "image/png"), mimeType: "image/png", byteSize: 120_000, width: 618, height: 618, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "a".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
    { id: system, ownerId: "owner-a", stickerId: sticker.stickerId, kind: "system", state: "ready", r2Key: objectKey("owner-a", system, "image/png"), mimeType: "image/png", byteSize: 400_000, width: 408, height: 408, frameCount: 10, durationSeconds: 1.6, fps: 10 / 1.6, sha256: "b".repeat(64), hasAlpha: true, createdAt: new Date(), readyAt: new Date() },
  ]);
  return {
    stickerId: sticker.stickerId,
    request: {
      revisionId,
      apngAssetId: apng,
      systemAssetId: system,
      mp4Background: { type: "solid" as const, color: "#FFFFFF" },
    },
  };
}

/**
 * The whole point of taking the publish off the durable runtime: it finishes inside the call, so
 * the client finds the job already terminal on the first read of the event stream instead of
 * waiting out four function invocations to be told the same thing.
 */
it("binds an export and reaches a terminal job without a workflow", async () => {
  const { stickerId, request } = await readyToPublish();
  const jobId = await createExportJob(db, "owner-a", stickerId, 0);

  const outcome = await publishExports(db, jobId, request);

  expect(outcome).toEqual({ state: "succeeded", retryable: false });
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  expect(job?.state).toBe("succeeded");
  expect(job?.completedAt).toBeTruthy();
  // Nothing was dispatched, so nothing recorded a run to watch.
  expect(job?.workflowRunId).toBeNull();
  // The published revision is the job, which is what makes a replay of the same publish return the
  // revision the first one minted rather than a second one.
  const published = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, jobId)).then(firstRow);
  expect(published?.parentRevisionId).toBe(request.revisionId);
  expect((await db.select().from(stickers).where(eq(stickers.id, stickerId)).then(firstRow))?.status).toBe("published");

  // The event stream the client reads is the same shape a workflow-driven publish left behind — it
  // is simply complete by the time anyone connects.
  const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, jobId));
  expect(events.map((event) => event.type)).toEqual(["queued", "started", "progress", "completed"]);
});

/**
 * A rejected rendition is a verdict on bytes that are already uploaded, so it fails the job once
 * and hands over the reason. Retrying would fail identically.
 */
it("fails the job with the server's reason when a rendition is refused", async () => {
  const { stickerId, request } = await readyToPublish();
  const jobId = await createExportJob(db, "owner-a", stickerId, 0);

  // An animated sticker without its sharing rendition: 422, and the same 422 every time.
  const outcome = await publishExports(db, jobId, { ...request, apngAssetId: undefined });

  expect(outcome).toEqual({ state: "failed", retryable: false });
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  expect(job?.state).toBe("failed");
  const failure = (await db.select().from(generationEvents).where(eq(generationEvents.jobId, jobId))).at(-1);
  expect(failure?.type).toBe("failed");
  expect((failure?.dataJson as { message: string }).message).toContain("sharing APNG");
  // The sticker is still a draft the user can publish again.
  expect((await db.select().from(stickers).where(eq(stickers.id, stickerId)).then(firstRow))?.status).not.toBe("published");
});

/**
 * Everything durability was there for. A failure that is not a verdict on the request keeps the
 * claimed, paid-for job and hands it to the workflow, whose retries still apply.
 */
it("defers to the workflow when the failure is not a verdict on the request", async () => {
  const { stickerId, request } = await readyToPublish();
  const jobId = await createExportJob(db, "owner-a", stickerId, 0);
  bindFailure.error = new Error("connection terminated unexpectedly");

  const outcome = await publishExports(db, jobId, request);

  expect(outcome).toEqual({ deferToWorkflow: true });
  // Claimed, not finished: `beginJobStep` reads the running state as a step it is re-running, so
  // the workflow picks the job up exactly where this left it.
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  expect(job?.state).toBe("running");
  expect(job?.completedAt).toBeNull();
});
