import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { StickerListResponseV1Schema } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { generationJobs } from "@/lib/db/schema";
import { listStickers } from "@/lib/services/sticker-summaries";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("sticker summary generation", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await seedUser(db, "owner");
  });

  afterEach(async () => {
    await close();
  });

  async function seedJob(stickerId: string, id: string, state: "queued" | "running" | "waiting" | "succeeded" | "failed") {
    await db.insert(generationJobs).values({ id, ownerId: "owner", stickerId, kind: "chat", state });
  }

  it("carries the active job, and only the active one, without duplicating the sticker", async () => {
    const busy = await seedPublishedSticker(db, "owner", { title: "Busy" });
    const idle = await seedPublishedSticker(db, "owner", { title: "Idle" });
    await seedJob(busy.stickerId, "job-done", "succeeded");
    await seedJob(busy.stickerId, "job-live", "running");
    await seedJob(idle.stickerId, "job-failed", "failed");

    const response = await listStickers(db, "owner");
    expect(() => StickerListResponseV1Schema.parse(response)).not.toThrow();
    expect(response.data).toHaveLength(2);
    const byTitle = Object.fromEntries(response.data.map((sticker) => [sticker.title, sticker]));
    expect(byTitle.Busy.generation).toEqual({ jobId: "job-live", kind: "chat", state: "running" });
    expect(byTitle.Idle.generation).toBeNull();
  });
});
