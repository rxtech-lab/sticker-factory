import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import { generationEvents, generationJobs, generationLiveActivities } from "@/lib/db/schema";
import { liveActivitySnapshot, pushLiveActivityUpdate } from "@/lib/notifications/live-activities";
import * as apns from "@/lib/notifications/apns";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("Live Activity backend snapshots", () => {
  let handle: Awaited<ReturnType<typeof createTestDatabase>>;
  let jobId: string;
  beforeEach(async () => {
    handle = await createTestDatabase();
    await seedUser(handle.db, "owner");
    const sticker = await seedPublishedSticker(handle.db, "owner");
    jobId = crypto.randomUUID();
    // Counts must also survive non-compose jobs.
    await handle.db.insert(generationJobs).values({ id: jobId, ownerId: "owner", stickerId: sticker.stickerId, kind: "chat", state: "running" });
  });
  afterEach(async () => { vi.restoreAllMocks(); await handle.close(); });
  async function event(data: Record<string, unknown>) {
    const [row] = await handle.db.insert(generationEvents).values({ jobId, ownerId: "owner", type: "progress", dataJson: data }).returning();
    return row;
  }
  const snapshot = () => liveActivitySnapshot(handle.db, "owner", jobId);

  it("polls without a push token and never creates a push registration", async () => {
    await event({ stage: "composing" });
    expect((await snapshot()).state.message).toBe("Composing the artwork");
    expect(await handle.db.select().from(generationLiveActivities)).toEqual([]);
    await expect(liveActivitySnapshot(handle.db, "other-owner", jobId)).rejects.toMatchObject({ status: 404 });
  });

  it("advances for notes and count-only events while retaining the latest text", async () => {
    await event({ stage: "composing", completedUnits: 0, totalUnits: 3, progressLabel: "Sprite sheets" });
    const note = await event({ note: "Drawing the cat expressions" });
    expect((await snapshot()).state).toMatchObject({ message: "Drawing the cat expressions", eventID: note.id, completedUnits: 0 });
    const count = await event({ completedUnits: 1, totalUnits: 3, progressLabel: "Sprite sheets" });
    expect((await snapshot()).state).toMatchObject({ message: "Drawing the cat expressions", eventID: count.id, completedUnits: 1, totalUnits: 3 });
    const cleared = await event({ clearProgress: true });
    expect((await snapshot()).state).toEqual({ message: "Drawing the cat expressions", phase: "running", eventID: cleared.id });
  });

  it("new stages replace old notes and completed tools do not restore their busy label", async () => {
    await event({ note: "Saved the artwork" });
    const stage = await event({ stage: "validating_candidate", clearProgress: true });
    await event({ toolName: "view_plan_image", toolStatus: "complete" });
    expect((await snapshot()).state).toEqual({ message: "Checking the result", phase: "running", eventID: stage.id });
  });

  it("honors legacy counters and clears all progress when the backend finishes", async () => {
    await event({ completedParts: 2, totalParts: 4 });
    expect((await snapshot()).state).toMatchObject({ completedUnits: 2, totalUnits: 4 });
    await handle.db.update(generationJobs).set({ state: "succeeded" }).where(eq(generationJobs.id, jobId));
    expect(await snapshot()).toMatchObject({ terminal: true, state: { phase: "completed", message: "Done!" } });
    expect((await snapshot()).state).not.toHaveProperty("completedUnits");
  });

  it("ends successful activities with Done and leaves dismissal to the system", async () => {
    vi.spyOn(apns, "getApnsConfig").mockReturnValue({
      keyId: "test", teamId: "test", privateKey: "unused", bundleId: "test",
    });
    const send = vi.spyOn(apns, "sendPushes").mockImplementation(async (pushes) =>
      pushes.map(({ token }) => ({ token, ok: true, status: 200, permanentlyGone: false })));
    await handle.db.insert(generationLiveActivities).values({
      activityId: "test-activity", ownerId: "owner", jobId, token: "a".repeat(64),
      environment: "sandbox", expiresAt: new Date(Date.now() + 60_000),
    });
    await event({ completedUnits: 6, totalUnits: 6 });
    await handle.db.update(generationJobs).set({ state: "succeeded" }).where(eq(generationJobs.id, jobId));

    await pushLiveActivityUpdate(handle.db, "owner", jobId);

    expect(send).toHaveBeenCalledOnce();
    const payload = send.mock.calls[0][0][0].payload.aps;
    expect(payload).toMatchObject({ event: "end", "content-state": { phase: "completed", message: "Done!" } });
    expect(payload).not.toHaveProperty("dismissal-date");
    expect(payload).not.toHaveProperty("stale-date");
  });
});
