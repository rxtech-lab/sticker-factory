import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { setDatabaseForTests } from "@/lib/db/client";
import { chatThreads, generationEvents, generationJobs } from "@/lib/db/schema";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { listChatMessages } from "@/lib/services/sticker-chat";
import { svgProgressReporter } from "@/workflows/sticker-generation/svg-progress";

afterEach(() => setDatabaseForTests(undefined));
it("persists SVG attempt cards and status events, including failure details after reopening chat", async () => {
  const { db, close } = await createTestDatabase(); setDatabaseForTests(db);
  try {
    await seedUser(db, "owner");
    const sticker = await seedPublishedSticker(db, "owner");
    await db.insert(chatThreads).values({ id: crypto.randomUUID(), ownerId: "owner", stickerId: sticker.stickerId });
    const [job] = await db.insert(generationJobs).values({ id: crypto.randomUUID(), ownerId: "owner", stickerId: sticker.stickerId, kind: "compose", state: "running" }).returning();
    const layer = { layerId: "hero", name: "Cat" };
    const report = svgProgressReporter(job, layer);
    const event = { stage: "validation" as const, attempt: 2, maxAttempts: 3, durationMs: 44165 };
    await report({ ...event, status: "started", durationMs: 0 });
    await report({ ...event, status: "failed", message: "Missing walk pose" });
    await report({ ...event, attempt: 3, stage: "authoring", status: "started" });
    await report({ ...event, attempt: 3, stage: "authoring", status: "complete" });
    let chat = await listChatMessages(db, "owner", sticker.stickerId);
    expect(chat.data.map(m => m.status)).toEqual(["failed", "complete"]);
    expect(JSON.parse(String(chat.data[0].toolDetails))).toMatchObject({ engine: "svg", attempt: 2, durationMs: 44165, message: "Missing walk pose", correction: expect.stringContaining("attempt 3 of 3") });
    const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, job.id));
    expect(events.some(e => e.dataJson.stage === "retrying_svg")).toBe(true);
    expect(events.some(e => e.dataJson.stage === "authoring_svg" && e.dataJson.note === "Attempt 3 of 3")).toBe(true);
    // Replaying interrupted work must not reuse completed cards or leave a stale spinner.
    await report({ ...event, attempt: 3, stage: "review", status: "started" });
    const resumed = svgProgressReporter(job, layer);
    await resumed({ ...event, attempt: 1, stage: "authoring", status: "started" });
    await resumed({ ...event, attempt: 1, stage: "authoring", status: "complete" });
    chat = await listChatMessages(db, "owner", sticker.stickerId);
    expect(chat.data.map(m => m.status)).toEqual(["failed", "complete", "failed", "complete"]);
    expect(chat.data.at(-1)?.content).toBe("create_svg Cat [hero] #4");
  } finally { await close(); }
});
