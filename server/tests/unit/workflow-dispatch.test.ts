import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { generationEvents, generationJobs, stickers, users } from "@/lib/db/schema";
import { createChatTurn, createCleanupJob, createSticker } from "@/lib/services/stickers";
import { startCleanupWorkflow, startGenerationWorkflow } from "@/lib/services/workflows";
import { createTestDatabase } from "@/tests/helpers/database";

const startMock = vi.hoisted(() => vi.fn());
vi.mock("workflow/api", () => ({ start: startMock }));

describe("workflow dispatch recovery", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    delete process.env.STICKER_FACTORY_INLINE_WORKFLOWS;
    startMock.mockReset();
    await db.insert(users).values({ id: "owner-a", createdAt: new Date(), updatedAt: new Date() });
  });

  afterEach(async () => close());

  it("restores a deleting project when durable cleanup cannot be dispatched", async () => {
    const sticker = await createSticker(db, "owner-a", { title: "Keep me", kind: "static", prompt: "Keep me", referenceAssetIds: [] });
    const jobId = await createCleanupJob(db, "owner-a", sticker.stickerId);
    startMock.mockRejectedValueOnce(new Error("workflow unavailable"));
    await expect(startCleanupWorkflow(db, jobId)).rejects.toThrow(/unavailable/);
    expect(await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow)).toMatchObject({ status: "draft", deletedAt: null });
    expect(await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow)).toMatchObject({ state: "failed", errorCode: "WORKFLOW_DISPATCH_FAILED" });
    expect((await db.select().from(generationEvents).where(eq(generationEvents.jobId, jobId))).at(-1)?.type).toBe("failed");
    await expect(createCleanupJob(db, "owner-a", sticker.stickerId)).resolves.toEqual(expect.any(String));
  });

  it("dispatches Quick generation as the workflow's single-step path", async () => {
    const sticker = await createSticker(db, "owner-a", {
      title: "Quick cat", kind: "static", prompt: "Quick cat", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Quick cat", intent: "generate", attachments: [], imagePlacement: "replace", quick: true,
    });

    startMock.mockResolvedValueOnce({ runId: "run-quick" });
    await expect(startGenerationWorkflow(db, turn.jobId)).resolves.toBe("run-quick");
    expect(startMock).toHaveBeenCalledWith(expect.any(Function), [turn.jobId, true, false]);
  });

  it("keeps ordinary generation on the durable workflow", async () => {
    const sticker = await createSticker(db, "owner-a", {
      title: "Careful cat", kind: "static", prompt: "Careful cat", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "Careful cat", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    startMock.mockResolvedValueOnce({ runId: "run-durable" });

    await expect(startGenerationWorkflow(db, turn.jobId)).resolves.toBe("run-durable");
    expect(startMock).toHaveBeenCalledWith(expect.any(Function), [turn.jobId, false, false]);
  });
});
