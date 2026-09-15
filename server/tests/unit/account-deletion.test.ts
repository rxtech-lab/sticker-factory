import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, creatorProfiles, deviceTokens, stickerPacks, stickers, users } from "@/lib/db/schema";
import {
  DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS,
  MAX_ACCOUNT_DELETION_DELAY_SECONDS,
  cancelAccountDeletion,
  computeDeletionScheduledAt,
  finalizeAccountDeletion,
  getAccountDeletionDelaySeconds,
  getDeletionStatus,
  scheduleAccountDeletion,
  sweepOverdueAccountDeletions,
} from "@/lib/services/account-deletion";
import { createPack, serializeCreator } from "@/lib/services/packs";
import { getObjectStore } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

const DAY = 24 * 60 * 60 * 1000;

describe("account deletion", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await seedUser(db, "creator", "Mika Lin");
  });

  afterEach(async () => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    await close();
  });

  async function pendingOf(userId: string) {
    const status = await getDeletionStatus(db, userId);
    return status?.pending ?? null;
  }

  describe("the grace period", () => {
    it("defaults to seven days and reads the override at call time", () => {
      expect(DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS).toBe(7 * 24 * 60 * 60);
      expect(getAccountDeletionDelaySeconds()).toBe(DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS);

      vi.stubEnv("ACCOUNT_DELETION_DELAY_SECONDS", "5");
      expect(getAccountDeletionDelaySeconds()).toBe(5);
    });

    it("falls back rather than accepting a delay that is not a whole number of seconds", () => {
      for (const raw of ["1.5", "abc", "-1", " ", ""]) {
        vi.stubEnv("ACCOUNT_DELETION_DELAY_SECONDS", raw);
        expect(getAccountDeletionDelaySeconds()).toBe(DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS);
      }
    });

    it("clamps an absurd delay so a typo cannot schedule a deletion nothing will run", () => {
      vi.stubEnv("ACCOUNT_DELETION_DELAY_SECONDS", String(99 * 365 * 24 * 60 * 60));
      expect(getAccountDeletionDelaySeconds()).toBe(MAX_ACCOUNT_DELETION_DELAY_SECONDS);
    });

    it("floors the scheduled instant to the second so it survives the round-trip", () => {
      const now = new Date("2026-01-01T00:00:00.619Z");
      const scheduled = computeDeletionScheduledAt(now, 60);
      expect(scheduled.getMilliseconds()).toBe(0);
      expect(scheduled.toISOString()).toBe("2026-01-01T00:01:00.000Z");
    });
  });

  describe("scheduling", () => {
    it("records the deadline and reads it back unchanged", async () => {
      const now = new Date("2026-01-01T00:00:00.000Z");
      const scheduledAt = new Date(now.getTime() + 7 * DAY);

      const result = await scheduleAccountDeletion(db, "creator", { scheduledAt, now });
      expect(result.ok).toBe(true);
      if (!result.ok) return;
      expect(result.alreadyScheduled).toBe(false);
      expect(result.pending.scheduledAt.toISOString()).toBe(scheduledAt.toISOString());

      const pending = await pendingOf("creator");
      expect(pending?.scheduledAt.toISOString()).toBe(scheduledAt.toISOString());
      expect(pending?.requestId).toBe(result.pending.requestId);
    });

    it("is idempotent: a second request keeps the original deadline", async () => {
      const now = new Date("2026-01-01T00:00:00.000Z");
      const first = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() + 7 * DAY),
        now,
      });
      expect(first.ok).toBe(true);
      if (!first.ok) return;

      // A week later the user taps again. The deadline must not slide out another week.
      const later = new Date(now.getTime() + 3 * DAY);
      const second = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(later.getTime() + 7 * DAY),
        now: later,
      });
      expect(second.ok).toBe(true);
      if (!second.ok) return;

      expect(second.alreadyScheduled).toBe(true);
      expect(second.pending.scheduledAt.toISOString()).toBe(first.pending.scheduledAt.toISOString());
      expect(second.pending.requestId).toBe(first.pending.requestId);
    });

    it("reports a user it has never seen rather than inventing a row", async () => {
      const result = await scheduleAccountDeletion(db, "nobody");
      expect(result).toEqual({ ok: false, reason: "not_found" });
    });
  });

  describe("cancelling", () => {
    it("clears the record", async () => {
      await scheduleAccountDeletion(db, "creator");
      expect(await pendingOf("creator")).not.toBeNull();

      expect(await cancelAccountDeletion(db, "creator")).toEqual({ ok: true, cancelled: true });
      expect(await pendingOf("creator")).toBeNull();
    });

    it("is a no-op, not an error, when nothing was scheduled", async () => {
      expect(await cancelAccountDeletion(db, "creator")).toEqual({ ok: true, cancelled: false });
    });

    it("stops a deletion that has already come due", async () => {
      const now = new Date("2026-01-01T00:00:00.000Z");
      const scheduled = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() - 1000),
        now,
      });
      expect(scheduled.ok).toBe(true);
      if (!scheduled.ok) return;

      await cancelAccountDeletion(db, "creator");

      const result = await finalizeAccountDeletion(db, "creator", scheduled.pending.requestId, now);
      expect(result).toEqual({ deleted: false, reason: "cancelled" });
    });
  });

  describe("the fencing token", () => {
    it("ignores a finalize belonging to a schedule the user already cancelled and replaced", async () => {
      const now = new Date("2026-01-01T00:00:00.000Z");
      const first = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() - 1000),
        now,
      });
      expect(first.ok).toBe(true);
      if (!first.ok) return;
      const staleRequestId = first.pending.requestId;

      await cancelAccountDeletion(db, "creator");
      const second = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() + 7 * DAY),
        now,
      });
      expect(second.ok).toBe(true);
      if (!second.ok) return;
      expect(second.pending.requestId).not.toBe(staleRequestId);

      // The sweep that was mid-flight when the user cancelled must not delete the new schedule's
      // account — its deadline is a week out.
      const result = await finalizeAccountDeletion(db, "creator", staleRequestId, now);
      expect(result).toEqual({ deleted: false, reason: "superseded" });
      expect(await pendingOf("creator")).not.toBeNull();
    });

    it("never deletes ahead of the advertised date", async () => {
      const now = new Date("2026-01-01T00:00:00.000Z");
      const scheduled = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() + 7 * DAY),
        now,
      });
      expect(scheduled.ok).toBe(true);
      if (!scheduled.ok) return;

      const result = await finalizeAccountDeletion(db, "creator", scheduled.pending.requestId, now);
      expect(result).toEqual({ deleted: false, reason: "not_due" });
    });
  });

  describe("finalizing", () => {
    /** Schedules a deletion that is already due and runs it. */
    async function deleteNow(userId: string, now = new Date()) {
      const scheduled = await scheduleAccountDeletion(db, userId, {
        scheduledAt: new Date(now.getTime() - 1000),
        now,
      });
      if (!scheduled.ok) throw new Error(`could not schedule: ${scheduled.reason}`);
      return finalizeAccountDeletion(db, userId, scheduled.pending.requestId, now);
    }

    it("purges an unpacked sticker and its objects", async () => {
      const seeded = await seedPublishedSticker(db, "creator", { title: "Private" });
      const store = getObjectStore();
      const keys = (await db.select({ r2Key: assets.r2Key }).from(assets)
        .where(eq(assets.stickerId, seeded.stickerId))).map((row) => row.r2Key);
      expect(keys.length).toBeGreaterThan(0);

      const result = await deleteNow("creator");
      expect(result.deleted).toBe(true);
      expect(result.purgedStickers).toBe(1);

      expect(await db.select().from(stickers).where(eq(stickers.id, seeded.stickerId)).then(firstRow)).toBeUndefined();
      for (const key of keys) {
        await expect(store.head(key)).rejects.toMatchObject({ code: "ASSET_OBJECT_MISSING" });
      }
    });

    it("keeps a sticker a published pack still needs, and keeps the pack", async () => {
      const kept = await seedPublishedSticker(db, "creator", { title: "Packed", messengerRenditions: true });
      const dropped = await seedPublishedSticker(db, "creator", { title: "Unpacked" });

      const pack = await createPack(db, "creator", {
        title: "Winter",
        stickerIds: [kept.stickerId],
        state: "published",
      });

      const result = await deleteNow("creator");
      expect(result.deleted).toBe(true);
      expect(result.keptStickers).toBe(1);
      expect(result.purgedStickers).toBe(1);

      expect(await db.select().from(stickers).where(eq(stickers.id, kept.stickerId)).then(firstRow)).toBeDefined();
      expect(await db.select().from(stickers).where(eq(stickers.id, dropped.stickerId)).then(firstRow)).toBeUndefined();

      const survivingPack = await db.select().from(stickerPacks).where(eq(stickerPacks.id, pack.id)).then(firstRow);
      expect(survivingPack?.state).toBe("published");

      // The kept sticker's renditions have to survive too, or the pack is unusable.
      const store = getObjectStore();
      const keptKeys = await db.select({ r2Key: assets.r2Key }).from(assets)
        .where(eq(assets.stickerId, kept.stickerId));
      expect(keptKeys.length).toBeGreaterThan(0);
      for (const { r2Key } of keptKeys) expect(await store.head(r2Key)).toBeDefined();
    });

    it("deletes a draft pack, which no one but its creator could see", async () => {
      await seedPublishedSticker(db, "creator");
      const draft = await createPack(db, "creator", { title: "Never shipped" });

      await deleteNow("creator");

      expect(await db.select().from(stickerPacks).where(eq(stickerPacks.id, draft.id)).then(firstRow)).toBeUndefined();
    });

    it("keeps the user row, tombstoned and anonymized, so published packs keep resolving", async () => {
      const now = new Date("2026-06-01T00:00:00.000Z");
      await db.update(users).set({ email: "mika@example.test" }).where(eq(users.id, "creator"));
      const sticker = await seedPublishedSticker(db, "creator");
      await createPack(db, "creator", {
        title: "Winter",
        stickerIds: [sticker.stickerId],
        state: "published",
      });

      await deleteNow("creator", now);

      const row = await db.select().from(users).where(eq(users.id, "creator")).then(firstRow);
      expect(row).toBeDefined();
      expect(row?.displayName).toBe("deleted-account");
      expect(row?.email).toBeNull();
      expect(row?.deletedAt?.toISOString()).toBe(now.toISOString());
      // Cleared, so the sweep never looks at this row again.
      expect(row?.deletionScheduledAt).toBeNull();
      expect(row?.deletionRequestId).toBeNull();

      const profile = await db.select().from(creatorProfiles)
        .where(eq(creatorProfiles.userId, "creator")).then(firstRow);
      expect(profile?.displayName).toBe("deleted-account");
      expect(profile?.bio).toBeNull();
      // The handle stays: it is in the published pack's URL.
      expect(profile?.handle).toBeTruthy();
    });

    it("removes what is keyed to the person rather than to a sticker", async () => {
      const now = new Date();
      await db.insert(deviceTokens).values({
        token: "a".repeat(64),
        userId: "creator",
        createdAt: now,
        updatedAt: now,
        lastSeenAt: now,
      });

      await deleteNow("creator");

      expect(await db.select().from(deviceTokens).where(eq(deviceTokens.userId, "creator")).then(firstRow))
        .toBeUndefined();
    });

    it("refuses to run twice", async () => {
      const now = new Date("2026-06-01T00:00:00.000Z");
      const scheduled = await scheduleAccountDeletion(db, "creator", {
        scheduledAt: new Date(now.getTime() - 1000),
        now,
      });
      expect(scheduled.ok).toBe(true);
      if (!scheduled.ok) return;

      expect((await finalizeAccountDeletion(db, "creator", scheduled.pending.requestId, now)).deleted).toBe(true);
      expect(await finalizeAccountDeletion(db, "creator", scheduled.pending.requestId, now))
        .toEqual({ deleted: false, reason: "already_deleted" });
    });

    it("will not schedule a new deletion for an account that is already gone", async () => {
      await deleteNow("creator");
      expect(await scheduleAccountDeletion(db, "creator")).toEqual({ ok: false, reason: "already_deleted" });
      expect(await cancelAccountDeletion(db, "creator")).toEqual({ ok: false, reason: "already_deleted" });
    });
  });

  describe("the sweep", () => {
    it("holds off until the deadline has cleared the grace window", async () => {
      const now = new Date("2026-06-01T00:00:00.000Z");
      // Due 60s ago — inside the 300s grace, so the identity provider may not have acted yet.
      await scheduleAccountDeletion(db, "creator", { scheduledAt: new Date(now.getTime() - 60_000), now });

      expect(await sweepOverdueAccountDeletions(db, { now })).toEqual({ deleted: [], skipped: [] });
      expect(await pendingOf("creator")).not.toBeNull();

      const later = new Date(now.getTime() + 10 * 60_000);
      expect(await sweepOverdueAccountDeletions(db, { now: later })).toEqual({ deleted: ["creator"], skipped: [] });
    });

    it("finalizes every account that has come due, and leaves the rest alone", async () => {
      await seedUser(db, "other", "Sam");
      const now = new Date("2026-06-01T00:00:00.000Z");
      await scheduleAccountDeletion(db, "creator", { scheduledAt: new Date(now.getTime() - 10 * 60_000), now });
      await scheduleAccountDeletion(db, "other", { scheduledAt: new Date(now.getTime() + 7 * DAY), now });

      const result = await sweepOverdueAccountDeletions(db, { now });
      expect(result.deleted).toEqual(["creator"]);
      expect(result.skipped).toEqual([]);
      expect(await pendingOf("other")).not.toBeNull();
    });
  });

  describe("the public byline", () => {
    it("reads deleted-account for a deleted creator, and never as the viewer", () => {
      const creator = serializeCreator(
        {
          profile: {
            userId: "creator",
            handle: "mika-a1b2c3",
            displayName: "Mika Lin",
            bio: "Stickers about cats",
            avatarAssetId: null,
            payoutStatus: "none",
            payoutProvider: null,
            payoutAccountRef: null,
            createdAt: new Date(),
            updatedAt: new Date(),
          },
          user: { id: "creator", displayName: "Mika Lin", deletedAt: new Date() },
        },
        // Even asked as though the viewer were the deleted account, the byline must not say "you":
        // nobody can be signed in as an account that no longer exists.
        { viewerId: "creator", packCount: 2 },
      );

      expect(creator.displayName).toBe("deleted-account");
      expect(creator.isSelf).toBe(false);
      expect(creator.bio).toBeNull();
      // The handle survives — it is the published pack's URL.
      expect(creator.handle).toBe("mika-a1b2c3");
      expect(creator.packCount).toBe(2);
    });

    it("is unchanged for a live creator", () => {
      const creator = serializeCreator(
        { profile: null, user: { id: "creator", displayName: "Mika Lin", deletedAt: null } },
        { viewerId: "creator" },
      );
      expect(creator.displayName).toBe("Mika Lin");
      expect(creator.isSelf).toBe(true);
    });
  });
});
