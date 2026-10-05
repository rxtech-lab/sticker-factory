import { and, eq, inArray, isNotNull, isNull, lte, notInArray } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import {
  assets,
  chatMessages,
  chatThreads,
  creatorProfiles,
  deviceTokens,
  generationEvents,
  generationJobs,
  idempotencyKeys,
  packInstalls,
  plans,
  stickerPackItems,
  stickerPacks,
  stickers,
  petEvents,
  userPets,
  users,
} from "@/lib/db/schema";
import { purgeStickerMediaImmediately } from "@/lib/services/assets";
import { DELETED_ACCOUNT_NAME, PUBLIC_PACK_STATES } from "@/lib/services/packs";
import { getObjectStore } from "@/lib/storage/r2";

/**
 * Delayed account deletion, mirrored from the identity provider.
 *
 * rxlab-auth owns whether the *account* exists and schedules its own deletion on the same 7-day
 * grace period, but it has no idea this application exists — nothing notifies a relying party when
 * it finalizes. So this service keeps its own copy of the deadline (adopted from the instant the
 * IdP hands back, so the two can never drift) and does its own purge on its own cron.
 *
 * The invariant that matters: **the `users` row is never deleted.** Every owner FK cascades from it,
 * so dropping it would take the creator's published packs with it — and a published pack is meant to
 * outlive its author's account. Deletion purges the private work and anonymizes what remains.
 */

export const DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS = 7 * 24 * 60 * 60; // 604800

/** A typo must not be able to schedule a deletion nothing will ever run. */
export const MAX_ACCOUNT_DELETION_DELAY_SECONDS = 365 * 24 * 60 * 60;

/**
 * Read at call time, never at module load, so tests and E2E can set it to a couple of seconds
 * without re-importing the module.
 */
export function getAccountDeletionDelaySeconds(): number {
  const raw = process.env.ACCOUNT_DELETION_DELAY_SECONDS;
  if (!raw) return DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS;
  // "1.5", "abc", "-1" and "" all fall back rather than produce a nonsense schedule.
  if (!/^\d+$/.test(raw.trim())) return DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS;
  const parsed = Number.parseInt(raw.trim(), 10);
  if (!Number.isFinite(parsed)) return DEFAULT_ACCOUNT_DELETION_DELAY_SECONDS;
  return Math.min(parsed, MAX_ACCOUNT_DELETION_DELAY_SECONDS);
}

/**
 * Drop sub-second precision.
 *
 * The instant an API response advertises has to be the instant a later read returns, or the app
 * shows one deadline and the cron honours another.
 */
export function floorToSecond(value: Date): Date {
  return new Date(Math.floor(value.getTime() / 1000) * 1000);
}

/** The absolute instant a deletion requested `now` should execute. */
export function computeDeletionScheduledAt(
  now: Date = new Date(),
  delaySeconds: number = getAccountDeletionDelaySeconds(),
): Date {
  return floorToSecond(new Date(now.getTime() + delaySeconds * 1000));
}

export interface PendingDeletion {
  scheduledAt: Date;
  requestedAt: Date;
  requestId: string;
}

export type FinalizeReason = "not_found" | "cancelled" | "superseded" | "not_due" | "already_deleted";

function toPendingDeletion(row: {
  deletionScheduledAt: Date | null;
  deletionRequestedAt: Date | null;
  deletionRequestId: string | null;
}): PendingDeletion | null {
  if (!row.deletionScheduledAt || !row.deletionRequestedAt || !row.deletionRequestId) return null;
  return {
    scheduledAt: row.deletionScheduledAt,
    requestedAt: row.deletionRequestedAt,
    requestId: row.deletionRequestId,
  };
}

const DELETION_COLUMNS = {
  deletionScheduledAt: users.deletionScheduledAt,
  deletionRequestedAt: users.deletionRequestedAt,
  deletionRequestId: users.deletionRequestId,
  deletedAt: users.deletedAt,
} as const;

export interface DeletionStatus {
  pending: PendingDeletion | null;
  deletedAt: Date | null;
}

export async function getDeletionStatus(db: Database, userId: string): Promise<DeletionStatus | null> {
  const row = await db.select(DELETION_COLUMNS).from(users).where(eq(users.id, userId)).then(firstRow);
  if (!row) return null;
  return { pending: toPendingDeletion(row), deletedAt: row.deletedAt };
}

export type ScheduleResult =
  | { ok: true; pending: PendingDeletion; alreadyScheduled: boolean }
  | { ok: false; reason: "not_found" | "already_deleted" };

/**
 * Record the pending deletion.
 *
 * Idempotent: an account already pending keeps its original deadline rather than sliding it a week
 * further out every time the button is tapped. `scheduledAt` is supplied by the caller so the route
 * can adopt the instant the identity provider chose.
 */
export async function scheduleAccountDeletion(
  db: Database,
  userId: string,
  options: { scheduledAt?: Date; now?: Date } = {},
): Promise<ScheduleResult> {
  // Floor up front so the value we return survives the round-trip and later comparisons.
  const now = floorToSecond(options.now ?? new Date());
  const scheduledAt = floorToSecond(options.scheduledAt ?? computeDeletionScheduledAt(now));

  return db.transaction(async (tx) => {
    const existingRow = await tx.select(DELETION_COLUMNS).from(users).where(eq(users.id, userId)).then(firstRow);
    if (!existingRow) return { ok: false, reason: "not_found" } as const;
    if (existingRow.deletedAt) return { ok: false, reason: "already_deleted" } as const;

    const existing = toPendingDeletion(existingRow);
    if (existing) return { ok: true, pending: existing, alreadyScheduled: true } as const;

    const pending: PendingDeletion = { scheduledAt, requestedAt: now, requestId: crypto.randomUUID() };
    await tx.update(users).set({
      deletionScheduledAt: pending.scheduledAt,
      deletionRequestedAt: pending.requestedAt,
      deletionRequestId: pending.requestId,
      updatedAt: now,
    }).where(and(eq(users.id, userId), isNull(users.deletionScheduledAt), isNull(users.deletedAt)));

    return { ok: true, pending, alreadyScheduled: false } as const;
  });
}

export type CancelResult =
  | { ok: true; cancelled: boolean }
  | { ok: false; reason: "not_found" | "already_deleted" };

/**
 * Stop a pending deletion.
 *
 * The clear is a guarded UPDATE inside a transaction rather than a read-then-write, so there is no
 * window in which a concurrent sweep can claim the schedule between our decision and our write.
 * Whichever of the two commits first wins outright: a cancel that lands leaves the sweep's guarded
 * claim matching zero rows, and a claim that lands leaves nothing for the cancel to clear.
 */
export async function cancelAccountDeletion(db: Database, userId: string): Promise<CancelResult> {
  return db.transaction(async (tx) => {
    const row = await tx.select(DELETION_COLUMNS).from(users).where(eq(users.id, userId)).then(firstRow);
    if (!row) return { ok: false, reason: "not_found" } as const;
    if (row.deletedAt) return { ok: false, reason: "already_deleted" } as const;

    const cleared = await tx.update(users).set({
      deletionScheduledAt: null,
      deletionRequestedAt: null,
      deletionRequestId: null,
      updatedAt: new Date(),
    }).where(and(
      eq(users.id, userId),
      isNotNull(users.deletionScheduledAt),
      isNull(users.deletedAt),
    )).returning({ id: users.id });

    return { ok: true, cancelled: cleared.length > 0 } as const;
  });
}

/**
 * Every sticker of this owner that a surviving public pack still needs.
 *
 * Membership is what earns a sticker its reprieve, not its own `published` status: a sticker the
 * creator published and then never packed is private work like any other draft.
 */
async function survivingStickerIds(db: Database, userId: string): Promise<string[]> {
  const rows = await db.selectDistinct({ id: stickers.id })
    .from(stickers)
    .innerJoin(stickerPackItems, eq(stickerPackItems.stickerId, stickers.id))
    .innerJoin(stickerPacks, eq(stickerPacks.id, stickerPackItems.packId))
    .where(and(
      eq(stickers.ownerId, userId),
      inArray(stickerPacks.state, [...PUBLIC_PACK_STATES]),
    ));
  return rows.map((row) => row.id);
}

/** R2 objects have no FK, so anything not reachable from a surviving sticker is deleted by hand. */
async function purgeUnboundAssets(db: Database, userId: string): Promise<void> {
  const rows = await db.select({ id: assets.id, r2Key: assets.r2Key })
    .from(assets)
    .where(and(eq(assets.ownerId, userId), isNull(assets.stickerId)));
  const store = getObjectStore();
  for (const asset of rows) {
    await store.delete(asset.r2Key);
    await db.delete(assets).where(eq(assets.id, asset.id));
  }
}

export interface FinalizeResult {
  deleted: boolean;
  reason?: FinalizeReason;
  purgedStickers?: number;
  keptStickers?: number;
}

/**
 * Execute a scheduled deletion. The only path the cron sweep uses.
 *
 * Three phases, in this order for reasons:
 *
 *  1. **Claim**, in a transaction, with the guard in the WHERE clause rather than in an `if` after a
 *     read. All three conditions matter: `deletion_request_id = requestId` proves this sweep still
 *     owns the schedule (what makes schedule -> cancel -> re-schedule safe — a stale claim finds a
 *     different id and does nothing); `deletion_scheduled_at IS NOT NULL` proves it was not
 *     cancelled; `<= now` means we never delete ahead of the date we advertised.
 *  2. **Purge**, outside any transaction. R2 deletes are network calls, and holding a Postgres
 *     transaction open across them would pin a connection for the length of a user's whole library.
 *  3. **Anonymize**, in a transaction, so the account never half-exists: the tombstone, the cleared
 *     schedule and the byline rewrite all land together.
 */
export async function finalizeAccountDeletion(
  db: Database,
  userId: string,
  requestId: string,
  now: Date = new Date(),
): Promise<FinalizeResult> {
  // Phase 1 — claim.
  const claimed = await db.transaction(async (tx) => {
    const row = await tx.select(DELETION_COLUMNS).from(users).where(eq(users.id, userId)).then(firstRow);
    if (!row) return { ok: false, reason: "not_found" } as const;
    if (row.deletedAt) return { ok: false, reason: "already_deleted" } as const;
    if (!row.deletionScheduledAt) return { ok: false, reason: "cancelled" } as const;
    if (row.deletionRequestId !== requestId) return { ok: false, reason: "superseded" } as const;
    if (row.deletionScheduledAt > now) return { ok: false, reason: "not_due" } as const;

    // Re-assert every condition in the WHERE clause: between the read above and this write another
    // sweep or a cancel may have committed.
    const rows = await tx.update(users)
      .set({ updatedAt: now })
      .where(and(
        eq(users.id, userId),
        eq(users.deletionRequestId, requestId),
        isNotNull(users.deletionScheduledAt),
        lte(users.deletionScheduledAt, now),
        isNull(users.deletedAt),
      ))
      .returning({ id: users.id });

    if (rows.length === 0) return { ok: false, reason: "cancelled" } as const;
    return { ok: true } as const;
  });

  if (!claimed.ok) return { deleted: false, reason: claimed.reason };

  // Phase 2 — purge.
  const keep = await survivingStickerIds(db, userId);
  const doomed = await db.select({ id: stickers.id })
    .from(stickers)
    .where(keep.length === 0
      ? eq(stickers.ownerId, userId)
      : and(eq(stickers.ownerId, userId), notInArray(stickers.id, keep)));

  for (const sticker of doomed) {
    // Reused wholesale: deletes every R2 object bound to the sticker, then the row, letting the FK
    // cascades take its revisions, thread, messages, jobs and pack memberships with it.
    await purgeStickerMediaImmediately(db, userId, sticker.id);
  }
  await purgeUnboundAssets(db, userId);

  // Phase 3 — anonymize and tombstone.
  await db.transaction(async (tx) => {
    // Packs that are not public have no reason to survive; their members are already gone, but the
    // pack row itself is only reachable by its creator.
    await tx.delete(stickerPacks).where(and(
      eq(stickerPacks.creatorId, userId),
      notInArray(stickerPacks.state, [...PUBLIC_PACK_STATES]),
    ));

    // Anything keyed to the person rather than to a sticker. The sticker cascades have already
    // taken most of these; the owner-scoped sweep catches rows belonging to surviving stickers and
    // any that were never bound to one.
    await tx.delete(deviceTokens).where(eq(deviceTokens.userId, userId));
    await tx.delete(packInstalls).where(eq(packInstalls.userId, userId));
    await tx.delete(userPets).where(eq(userPets.userId, userId));
    await tx.delete(petEvents).where(eq(petEvents.userId, userId));
    await tx.delete(idempotencyKeys).where(eq(idempotencyKeys.ownerId, userId));
    await tx.delete(chatMessages).where(eq(chatMessages.ownerId, userId));
    await tx.delete(chatThreads).where(eq(chatThreads.ownerId, userId));
    await tx.delete(plans).where(eq(plans.ownerId, userId));
    await tx.delete(generationEvents).where(eq(generationEvents.ownerId, userId));
    await tx.delete(generationJobs).where(eq(generationJobs.ownerId, userId));

    // The public identity survives, stripped to the handle. The handle itself stays: it is in every
    // published pack URL, and the schema calls it immutable once shared.
    await tx.update(creatorProfiles).set({
      displayName: DELETED_ACCOUNT_NAME,
      bio: null,
      avatarAssetId: null,
      updatedAt: now,
    }).where(eq(creatorProfiles.userId, userId));

    await tx.update(users).set({
      email: null,
      displayName: DELETED_ACCOUNT_NAME,
      deletedAt: now,
      // Cleared so the sweep never looks at this row again.
      deletionScheduledAt: null,
      deletionRequestedAt: null,
      deletionRequestId: null,
      updatedAt: now,
    }).where(eq(users.id, userId));
  });

  return { deleted: true, purgedStickers: doomed.length, keptStickers: keep.length };
}

export interface SweepResult {
  deleted: string[];
  skipped: string[];
}

/**
 * Finalize every deletion that has come due. Driven hourly by `/api/cron/account-deletion`.
 *
 * `graceSeconds` is slack against clock skew between this app and the identity provider, so we
 * never purge a user's stickers in the minute *before* the account itself goes.
 */
export async function sweepOverdueAccountDeletions(
  db: Database,
  params: { limit?: number; graceSeconds?: number; now?: Date } = {},
): Promise<SweepResult> {
  const limit = params.limit ?? 100;
  const graceSeconds = params.graceSeconds ?? 300;
  const now = params.now ?? new Date();
  const cutoff = new Date(now.getTime() - graceSeconds * 1000);

  const overdue = await db.select({ id: users.id, requestId: users.deletionRequestId })
    .from(users)
    .where(and(
      isNotNull(users.deletionScheduledAt),
      lte(users.deletionScheduledAt, cutoff),
      isNull(users.deletedAt),
    ))
    .orderBy(users.deletionScheduledAt)
    .limit(limit);

  const deleted: string[] = [];
  const skipped: string[] = [];

  for (const row of overdue) {
    if (!row.requestId) {
      // A schedule with no fencing token cannot be claimed safely; leave it for an operator.
      skipped.push(row.id);
      continue;
    }
    const result = await finalizeAccountDeletion(db, row.id, row.requestId, now);
    (result.deleted ? deleted : skipped).push(row.id);
  }

  return { deleted, skipped };
}
