import { and, desc, eq, inArray, isNull, lt, or, sql, type SQL } from "drizzle-orm";
import type { PgUpdateSetSource } from "drizzle-orm/pg-core";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetEventV1, PetSignalsV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petEvents, userPets, userWallets, type PetStatsValues, type UserPetRow, type UserWalletRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { buildIdentity, fallbackIdentity } from "@/lib/pets/identity";
import { petLog, petRandom } from "@/lib/pets/log";
import { ATTENTION_KINDS } from "@/lib/pets/neglect";
import { EMPTY_SIGNALS, localDate } from "@/lib/pets/signals";
import { dailyGold } from "@/lib/pets/daily-gold";
import { applyEffects, initialStats, STARTING_GOLD, withGold, withoutGold, type PetEffects, type PetStats } from "@/lib/pets/stats";
import { walkDetail, walkReward } from "@/lib/pets/walk";
import type { StickerControl } from "@/lib/contracts/configuration";
import type { AiReferenceImage } from "@/lib/ai/gateway-contracts";

export type PetEventKind = PetEventV1["kind"];

/** One thing that happened to the pet, with effects already personalized to it. */
export type PetChange = {
  kind: PetEventKind;
  title: string;
  detail: string;
  effects: PetEffects;
  signals?: PetSignalsV1 | null;
  debug?: Record<string, unknown>;
};

/** The caller's pet, read with the owner's wallet: gold is theirs, shared by every pet they have. */
export type PetRow = UserPetRow & { wallet: UserWalletRow | null };

export async function petRow(db: Database, userId: string): Promise<PetRow | undefined> {
  const row = await db.select({ pet: userPets, wallet: userWallets }).from(userPets)
    .leftJoin(userWallets, eq(userWallets.userId, userPets.userId))
    .where(eq(userPets.userId, userId))
    .then(firstRow);
  return row && { ...row.pet, wallet: row.wallet };
}

/** The owner's gold, or what a new owner starts with. */
export async function walletGold(db: Database, userId: string): Promise<number> {
  const wallet = await db.select({ gold: userWallets.gold }).from(userWallets).where(eq(userWallets.userId, userId)).then(firstRow);
  return wallet?.gold ?? STARTING_GOLD;
}

/**
 * Opens the owner's wallet with the starting purse, unless they already have one. The starting
 * purse is the first day's gold: the daily allowance begins tomorrow.
 */
export async function ensureWallet(db: Database, userId: string, timeZone: string | undefined): Promise<void> {
  const now = new Date();
  await db.insert(userWallets).values({ userId, gold: STARTING_GOLD, dailyGoldDate: localDate(now, timeZone), createdAt: now, updatedAt: now })
    .onConflictDoNothing();
}

/** When the owner last spent time with this life's pet, or null if the diary has no such line. */
export async function lastAttendedAt(db: Database, userId: string, lifeId: string): Promise<Date | null> {
  const latest = await db.select({ createdAt: petEvents.createdAt }).from(petEvents)
    .where(and(eq(petEvents.userId, userId), eq(petEvents.lifeId, lifeId), inArray(petEvents.kind, [...ATTENTION_KINDS])))
    .orderBy(desc(petEvents.createdAt))
    .limit(1)
    .then(firstRow);
  return latest?.createdAt ?? null;
}

/** The pet's stats, with the owner's gold. */
export function currentStats(row: PetRow): PetStats {
  return { ...withoutGold(row.statsJson ?? initialStats(row.identityJson)), gold: row.wallet?.gold ?? STARTING_GOLD };
}

/** Thrown inside the commit's transaction when the wallet moved underneath it, to roll back and retry. */
class WalletConflict extends Error {}

/**
 * Applies `changes` to the pet's stats in order and writes a diary line for each.
 *
 * The stats are read, changed and written back only if nobody else wrote them meanwhile — a send
 * being read while the owner taps an action must not lose either one — so the slow part (asking a
 * model) happens before this, and this only re-adds deltas. Null when the pet stopped being this
 * life, or `where` no longer holds.
 *
 * Today's gold allowance, if not yet granted, and gold the owner's walk has earned since it was
 * last paid land first, as their own lines, worked out again on every attempt so a retried write
 * never pays the same day or steps twice. Gold goes to the owner's wallet in the same transaction
 * as the pet's other stats.
 */
export async function commitPetChange(
  db: Database,
  userId: string,
  input: { lifeId: string; changes: PetChange[]; set?: PgUpdateSetSource<typeof userPets>; where?: SQL },
): Promise<{ before: PetStatsValues; after: PetStatsValues } | null> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const row = await petRow(db, userId);
    if (!row || row.lifeId !== input.lifeId) return null;
    const before = currentStats(row);
    let stats = before;
    const now = new Date();
    const daily = dailyGold(row.contextJson, row.wallet, now);
    const walk = walkReward({ contextJson: row.contextJson, walkGoldJson: row.wallet?.walkGoldJson ?? null }, now);
    const changes: PetChange[] = [
      ...(daily ? [{
        kind: "special" as const,
        title: "Daily gold",
        detail: `${daily.gold} gold for a new day.`,
        effects: { happiness: 0, hp: 0, energy: 0, gold: daily.gold },
        debug: { source: "daily-gold", date: daily.date },
      }] : []),
      ...(walk ? [{
        kind: "special" as const,
        title: "Walk reward",
        detail: walkDetail(walk),
        // Resting energy, like any other recovery: not scaled by the pet's energy multiplier.
        effects: { happiness: 0, hp: 0, energy: walk.energy, gold: walk.gold },
        debug: { source: "walk", steps: walk.steps, paidBefore: row.wallet?.walkGoldJson ?? null },
      }] : []),
      ...input.changes,
    ];
    const lines = changes.map((change) => {
      const statsBefore = stats;
      stats = applyEffects(stats, change.effects, row.identityJson);
      return { change, statsBefore, statsAfter: stats };
    });
    const { gold } = stats;
    let updated: boolean;
    try {
      updated = await db.transaction(async (tx) => {
        const written = await tx.update(userPets).set({ ...input.set, statsJson: withoutGold(stats) })
          .where(and(
            eq(userPets.userId, userId),
            eq(userPets.lifeId, input.lifeId),
            row.statsJson ? sql`${userPets.statsJson} = ${JSON.stringify(row.statsJson)}::jsonb` : isNull(userPets.statsJson),
            input.where,
          ))
          .returning({ userId: userPets.userId });
        if (!written.length) return false;
        if (!row.wallet || daily || walk || gold !== row.wallet.gold) {
          const wallet = {
            gold,
            walkGoldJson: walk?.ledger ?? row.wallet?.walkGoldJson ?? null,
            dailyGoldDate: daily?.date ?? row.wallet?.dailyGoldDate ?? null,
            version: (row.wallet?.version ?? -1) + 1,
            updatedAt: now,
          };
          const paid = row.wallet
            ? await tx.update(userWallets).set(wallet)
              .where(and(eq(userWallets.userId, userId), eq(userWallets.version, row.wallet.version)))
              .returning({ userId: userWallets.userId })
            : await tx.insert(userWallets).values({ userId, createdAt: now, ...wallet }).onConflictDoNothing()
              .returning({ userId: userWallets.userId });
          if (!paid.length) throw new WalletConflict();
        }
        return true;
      });
    } catch (error) {
      if (error instanceof WalletConflict) continue;
      throw error;
    }
    if (!updated) continue;
    const at = now.getTime();
    if (lines.length) {
      await db.insert(petEvents).values(lines.map(({ change, statsBefore, statsAfter }, index) => ({
        id: crypto.randomUUID(),
        userId,
        lifeId: input.lifeId,
        stickerId: row.stickerId,
        kind: change.kind,
        title: change.title.slice(0, 120),
        detail: change.detail.slice(0, 400),
        effectsJson: change.effects,
        statsBeforeJson: statsBefore,
        statsAfterJson: statsAfter,
        signalsJson: change.signals ?? null,
        debugJson: change.debug ?? {},
        // A millisecond apart, so lines written together keep their order in the diary.
        createdAt: new Date(at + index),
      })));
    }
    for (const { change, statsBefore, statsAfter } of lines) {
      petLog("stats:changed", { userId, lifeId: input.lifeId, kind: change.kind, title: change.title,
        effects: change.effects, before: statsBefore, after: statsAfter, attempt });
    }
    return { before, after: stats };
  }
  petLog("stats:conflict", { userId, lifeId: input.lifeId, kinds: input.changes.map((change) => change.kind) });
  return null;
}

/**
 * Gives a pet from before identities a life id and an identity, so everything after can assume
 * both. Generated once: a racing second call finds the column filled and reads it back.
 */
export async function ensurePetIdentity(
  db: Database,
  row: PetRow,
  describe: () => Promise<{ title: string; controls: StickerControl[]; image: AiReferenceImage | null }>,
): Promise<PetRow> {
  if (row.identityJson && row.lifeId) return row;
  const now = new Date();
  let identity = row.identityJson;
  let source = "existing";
  if (!identity) {
    const birth = row.signalsJson ?? EMPTY_SIGNALS;
    try {
      const pet = await describe();
      const persona = await getAiProvider().generatePetPersona({ petTitle: pet.title, controls: pet.controls, image: pet.image, birth });
      identity = buildIdentity(persona, birth, now, petRandom);
      source = "model";
    } catch (error) {
      petLog("identity:fallback", { userId: row.userId, error: describeError(error) });
      identity = fallbackIdentity(row.stickerId, birth, now);
      source = "fallback";
    }
  }
  await db.update(userPets).set({
    identityJson: sql`COALESCE(${userPets.identityJson}, ${JSON.stringify(identity)}::jsonb)`,
    lifeId: sql`COALESCE(${userPets.lifeId}, ${crypto.randomUUID()})`,
  }).where(and(eq(userPets.userId, row.userId), eq(userPets.stickerId, row.stickerId)));
  const updated = await petRow(db, row.userId);
  if (!updated?.lifeId) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  petLog("identity:ensured", { userId: row.userId, lifeId: updated.lifeId, source, class: updated.identityJson?.class });
  return updated;
}

/** Most recent first, `limit` at a time, for the current life only. */
export async function listPetEvents(
  db: Database,
  userId: string,
  options: { limit: number; cursor?: string | null },
): Promise<{ events: PetEventV1[]; nextCursor: string | null }> {
  const row = await petRow(db, userId);
  if (!row?.lifeId) return { events: [], nextCursor: null };
  let after: SQL | undefined;
  if (options.cursor) {
    const [at, id] = Buffer.from(options.cursor, "base64url").toString("utf8").split("|");
    const date = new Date(at);
    if (!id || Number.isNaN(date.getTime())) throw new ApiError(400, "INVALID_CURSOR", "The cursor is not valid.");
    after = or(lt(petEvents.createdAt, date), and(eq(petEvents.createdAt, date), lt(petEvents.id, id)));
  }
  const rows = await db.select().from(petEvents)
    .where(and(eq(petEvents.userId, userId), eq(petEvents.lifeId, row.lifeId), after))
    .orderBy(desc(petEvents.createdAt), desc(petEvents.id))
    .limit(options.limit + 1);
  const page = rows.slice(0, options.limit);
  const last = page.at(-1);
  return {
    events: page.map((event) => ({
      id: event.id,
      kind: event.kind,
      title: event.title,
      detail: event.detail,
      // Lines from before gold read as having none rather than as the starting purse.
      effects: withGold(event.effectsJson, 0),
      statsBefore: withGold(event.statsBeforeJson, 0),
      statsAfter: withGold(event.statsAfterJson, 0),
      signals: event.signalsJson,
      debug: event.debugJson,
      createdAt: event.createdAt.toISOString(),
    })),
    nextCursor: rows.length > options.limit && last
      ? Buffer.from(`${last.createdAt.toISOString()}|${last.id}`, "utf8").toString("base64url") : null,
  };
}
