import { and, asc, eq, gt, isNull, sql } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { userWalletGrants, users, type UserWalletGrantRow } from "@/lib/db/schema";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import {
  adjustBalance,
  fetchBalance,
  InsufficientCreditsError,
  releaseReservation,
  reserveCredits,
  settleReservation,
} from "./client";
import { subscriptionEnabled, type BillingEnvironment } from "./config";
import { requestBillingEnvironment } from "./environment";

/**
 * The owner's pet gold is a balance in RxSubscription, unit `gold`, beside their points: one purse
 * for every pet they have, which a points pack can fill as well as a walk.
 *
 * Every move is written to `user_wallet_grants` first, in the same transaction as the pet change
 * it belongs to, and carried to RxSubscription after, keyed by the row's id — so a crash between
 * the two only delays the gold, and a retry never moves it twice. A spend is held in RxSubscription
 * before its row is written, so the owner can never spend gold they do not have; the row settles
 * the hold, and a change that does not commit releases it.
 *
 * With billing unconfigured — tests and local development — the rows themselves are the purse.
 */
export const GOLD_UNIT = "gold";

/** Long enough for a pet change to commit and be carried; a lost one gives the gold back. */
const HOLD_TTL_SECONDS = 3_600;

export class NotEnoughGoldError extends Error {
  constructor(readonly available: number, readonly required: number) {
    super(`Not enough gold: ${available} available, ${required} required`);
    this.name = "NotEnoughGoldError";
  }
}

type GoldRow = Pick<UserWalletGrantRow, "id" | "userId" | "gold" | "reservationId">;

interface GoldBank {
  /** What the owner can spend, gold still being carried included. */
  balance(db: Database, userId: string, environment: BillingEnvironment | null): Promise<number>;
  /** Holds gold for a spend about to be written; the reservation to settle, or null for none. */
  hold(db: Database, input: { userId: string; amount: number; key: string; description: string },
    environment: BillingEnvironment | null): Promise<string | null>;
  release(reservationId: string, key: string, environment: BillingEnvironment | null): Promise<void>;
  carry(row: GoldRow, environment: BillingEnvironment | null): Promise<void>;
}

/** Gold written here and not carried yet. Spends are already held, so only earnings count. */
async function pendingGold(db: Database, userId: string): Promise<number> {
  const row = await db.select({ gold: sql<number>`coalesce(sum(${userWalletGrants.gold}), 0)::int` })
    .from(userWalletGrants)
    .where(and(eq(userWalletGrants.userId, userId), isNull(userWalletGrants.settledAt), gt(userWalletGrants.gold, 0)))
    .then(firstRow);
  return row?.gold ?? 0;
}

const remoteBank: GoldBank = {
  async balance(db, userId, environment) {
    const [balance, pending] = await Promise.all([fetchBalance(userId, GOLD_UNIT, environment), pendingGold(db, userId)]);
    return Math.max(0, balance?.available ?? 0) + pending;
  },
  async hold(_db, input, environment) {
    try {
      const reservation = await reserveCredits({
        rxlabUserId: input.userId, unit: GOLD_UNIT, amount: input.amount, idempotencyKey: `hold:${input.key}`,
        description: input.description, expiresInSeconds: HOLD_TTL_SECONDS,
      }, environment);
      return reservation.reservationId;
    } catch (error) {
      if (error instanceof InsufficientCreditsError) throw new NotEnoughGoldError(error.available, error.required);
      throw error;
    }
  },
  async release(reservationId, key, environment) {
    await releaseReservation({ reservationId, idempotencyKey: `release:${key}`, reason: "Pet change did not commit" }, environment);
  },
  async carry(row, environment) {
    if (row.gold > 0) {
      await adjustBalance({ rxlabUserId: row.userId, unit: GOLD_UNIT, amount: row.gold, operation: "credit",
        idempotencyKey: row.id, description: "Pet gold", metadata: { grantId: row.id } }, environment);
    } else if (row.gold < 0 && row.reservationId) {
      // Settles even a hold that has expired, from what the owner has left.
      await settleReservation({ reservationId: row.reservationId, amount: -row.gold, idempotencyKey: `settle:${row.id}`,
        description: "Pet gold", metadata: { grantId: row.id } }, environment);
    } else if (row.gold < 0) {
      await adjustBalance({ rxlabUserId: row.userId, unit: GOLD_UNIT, amount: -row.gold, operation: "debit",
        idempotencyKey: row.id, description: "Pet gold", metadata: { grantId: row.id } }, environment);
    }
  },
};

/** Unconfigured billing: the purse is the sum of every row, so there is nothing to carry. */
const localBank: GoldBank = {
  async balance(db, userId) {
    const row = await db.select({ gold: sql<number>`coalesce(sum(${userWalletGrants.gold}), 0)::int` })
      .from(userWalletGrants).where(eq(userWalletGrants.userId, userId)).then(firstRow);
    return Math.max(0, row?.gold ?? 0);
  },
  async hold(db, input) {
    const available = await localBank.balance(db, input.userId, null);
    if (available < input.amount) throw new NotEnoughGoldError(available, input.amount);
    return null;
  },
  async release() {},
  async carry() {},
};

function goldBank(): GoldBank {
  return subscriptionEnabled() ? remoteBank : localBank;
}

/**
 * Where the owner's gold is: the request's verified billing environment, or outside a request —
 * a workflow, the pet's own life — the one Apple last proved for them.
 *
 * Resolves the request's environment, which may write the users table: call it before, never
 * inside, a transaction.
 */
export async function goldEnvironment(db: Database, userId: string): Promise<BillingEnvironment | null> {
  if (!subscriptionEnabled()) return null;
  const requested = await requestBillingEnvironment();
  if (requested) return requested;
  const splitKeys = Boolean(process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY?.trim() ||
    process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY?.trim());
  if (!splitKeys) return null;
  const row = await db.select({ environment: users.lastBillingEnvironment }).from(users)
    .where(eq(users.id, userId)).then(firstRow);
  return row?.environment ?? "production";
}

/**
 * Carries the owner's gold moves that are not in RxSubscription yet, oldest first. Stops at the
 * first that fails, leaving it and the rest for the next try. Never throws.
 */
export async function carryGold(db: Database, userId: string): Promise<boolean> {
  const bank = goldBank();
  const pending = await db.select().from(userWalletGrants)
    .where(and(eq(userWalletGrants.userId, userId), isNull(userWalletGrants.settledAt)))
    .orderBy(asc(userWalletGrants.createdAt));
  let fallback: Promise<BillingEnvironment | null> | undefined;
  for (const row of pending) {
    try {
      const environment = row.billingEnvironment ?? await (fallback ??= goldEnvironment(db, userId));
      await bank.carry(row, environment);
      await db.update(userWalletGrants).set({ settledAt: new Date() })
        .where(and(eq(userWalletGrants.id, row.id), isNull(userWalletGrants.settledAt)));
    } catch (error) {
      petLog("gold:carry-failed", { userId, grantId: row.id, gold: row.gold, error: describeError(error) });
      return false;
    }
  }
  return true;
}

/** The owner's gold, after carrying whatever is waiting. */
export async function goldBalance(db: Database, userId: string, environment?: BillingEnvironment | null): Promise<number> {
  await carryGold(db, userId);
  return goldBank().balance(db, userId, environment === undefined ? await goldEnvironment(db, userId) : environment);
}

/** Holds `amount` for a spend about to be written. @throws NotEnoughGoldError */
export async function holdGold(
  db: Database,
  input: { userId: string; amount: number; key: string; description: string },
  environment: BillingEnvironment | null,
): Promise<string | null> {
  return goldBank().hold(db, input, environment);
}

/** Gives back a hold whose change did not commit. Never throws: an unreleased hold expires. */
export async function releaseGold(reservationId: string | null, key: string, environment: BillingEnvironment | null): Promise<void> {
  if (!reservationId) return;
  try {
    await goldBank().release(reservationId, key, environment);
  } catch (error) {
    petLog("gold:release-failed", { reservationId, key, error: describeError(error) });
  }
}
