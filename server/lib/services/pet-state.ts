import { and, desc, eq, inArray, isNull, lt, or, sql, type SQL } from "drizzle-orm";
import type { PgUpdateSetSource } from "drizzle-orm/pg-core";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetEventV1, PetSignalsV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petEvents, petRooms, petThemes, userPets, userWalletGrants, userWallets, type PetRoomRow, type PetStatsValues, type PetThemeRow, type UserPetRow, type UserWalletRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { buildIdentity, fallbackIdentity } from "@/lib/pets/identity";
import { petLog, petRandom } from "@/lib/pets/log";
import { isMemorable, queuePetMemory } from "@/lib/services/pet-memory";
import { ATTENTION_KINDS } from "@/lib/pets/neglect";
import { EMPTY_SIGNALS, localDate } from "@/lib/pets/signals";
import { dailyGold } from "@/lib/pets/daily-gold";
import { describeRoomEffects, roomComfortDate } from "@/lib/pets/rooms";
import { applyEffects, initialStats, STARTING_GOLD, withGold, withoutGold, type PetEffects, type PetStats } from "@/lib/pets/stats";
import { carryGold, goldBalance, goldEnvironment, holdGold, NotEnoughGoldError, releaseGold } from "@/lib/subscription/gold";
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

/**
 * The caller's pet, read with the owner's wallet and gold — theirs, shared by every pet they have,
 * kept in RxSubscription — the room it lives in, and the place it has gone.
 */
export type PetRow = UserPetRow & { wallet: UserWalletRow | null; room: PetRoomRow | null; theme: PetThemeRow | null; gold: number };

export async function petRow(db: Database, userId: string): Promise<PetRow | undefined> {
  const row = await db.select({ pet: userPets, wallet: userWallets, room: petRooms, theme: petThemes }).from(userPets)
    .leftJoin(userWallets, eq(userWallets.userId, userPets.userId))
    .leftJoin(petRooms, and(eq(petRooms.id, userPets.roomId), eq(petRooms.state, "owned")))
    .leftJoin(petThemes, eq(petThemes.id, userPets.themeId))
    .where(eq(userPets.userId, userId))
    .then(firstRow);
  return row && { ...row.pet, wallet: row.wallet, room: row.room, theme: row.theme, gold: await goldBalance(db, userId) };
}

/**
 * Opens the owner's wallet with the starting purse, unless they already have one. The starting
 * purse is the first day's gold: the daily allowance begins tomorrow. Whoever opens the wallet
 * queues the purse, once, and carries it.
 */
export async function ensureWallet(db: Database, userId: string, timeZone: string | undefined): Promise<void> {
  const now = new Date();
  const environment = await goldEnvironment(db, userId);
  const opened = await db.transaction(async (tx) => {
    const created = await tx.insert(userWallets).values({ userId, dailyGoldDate: localDate(now, timeZone), createdAt: now, updatedAt: now })
      .onConflictDoNothing()
      .returning({ userId: userWallets.userId });
    if (!created.length) return false;
    await tx.insert(userWalletGrants).values({ id: `starting:${userId}`, userId, kind: "starting", gold: STARTING_GOLD,
      billingEnvironment: environment, createdAt: now }).onConflictDoNothing();
    return true;
  });
  if (opened) await carryGold(db, userId);
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

/**
 * The weather the pet last felt: the latest diary line in this life that knew the weather. Not the
 * row's `signalsJson`, which a phone refresh rewrites between visits — the pet would never notice
 * a change it was not there for.
 */
export async function lastFeltWeather(db: Database, userId: string, lifeId: string): Promise<PetSignalsV1["weather"]> {
  const latest = await db.select({ signals: petEvents.signalsJson }).from(petEvents)
    .where(and(eq(petEvents.userId, userId), eq(petEvents.lifeId, lifeId),
      sql`jsonb_typeof(${petEvents.signalsJson}->'weather') = 'object'`))
    .orderBy(desc(petEvents.createdAt))
    .limit(1)
    .then(firstRow);
  return latest?.signals?.weather ?? null;
}

/** Whether the pet already read tomorrow's forecast to its owner on this local date. */
export async function remindedForecastOn(db: Database, userId: string, lifeId: string, date: string): Promise<boolean> {
  const found = await db.select({ id: petEvents.id }).from(petEvents)
    .where(and(eq(petEvents.userId, userId), eq(petEvents.lifeId, lifeId),
      sql`${petEvents.debugJson}->>'reminderDate' = ${date}`))
    .limit(1)
    .then(firstRow);
  return !!found;
}

/** The pet's stats, with the owner's gold. */
export function currentStats(row: PetRow): PetStats {
  return { ...withoutGold(row.statsJson ?? initialStats(row.identityJson)), gold: row.gold };
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
 * never pays the same day or steps twice. The gold the change nets is queued for RxSubscription in
 * the same transaction as the pet's other stats, and carried after; gold it spends is held there
 * first, and given back if the change does not commit. The day's comfort from the room the pet
 * lives in is written alongside.
 *
 * `price` is gold the change spends: refused with `PET_NOT_ENOUGH_GOLD` when the owner has less, so
 * two purchases racing can never take the purse below what they cost.
 */
export async function commitPetChange(
  db: Database,
  userId: string,
  input: { lifeId: string; changes: PetChange[]; set?: PgUpdateSetSource<typeof userPets>; where?: SQL; price?: number },
): Promise<{ before: PetStatsValues; after: PetStatsValues } | null> {
  // Resolved before any transaction: it may write the users table.
  const environment = await goldEnvironment(db, userId);
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const row = await petRow(db, userId);
    if (!row || row.lifeId !== input.lifeId) return null;
    const { wallet } = row;
    if (!wallet) {
      await ensureWallet(db, userId, row.contextJson?.timeZone);
      continue;
    }
    const before = currentStats(row);
    if (input.price && before.gold < input.price) {
      throw new ApiError(422, "PET_NOT_ENOUGH_GOLD", `This costs ${input.price} gold, and you have ${before.gold}.`);
    }
    let stats = before;
    const now = new Date();
    const daily = dailyGold(row.contextJson, row.wallet, now);
    const comfortDate = row.room ? roomComfortDate(row.contextJson, row.roomEffectDate, now) : null;
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
      ...(row.room && comfortDate ? [{
        kind: "room" as const,
        title: `A day in ${row.room.title}`,
        detail: `${describeRoomEffects(row.room.effectsJson)} from living in ${row.room.title}.`,
        // The room's own effect, as it says on the door: not scaled by the pet's energy multiplier.
        effects: { ...row.room.effectsJson, gold: 0 },
        debug: { source: "room", roomId: row.room.id, date: comfortDate },
      }] : []),
      ...input.changes,
    ];
    const lines = changes.map((change) => {
      const statsBefore = stats;
      stats = applyEffects(stats, change.effects, row.identityJson);
      return { change, statsBefore, statsAfter: stats };
    });
    const gold = stats.gold - before.gold;
    const grantId = `pet:${crypto.randomUUID()}`;
    let reservationId: string | null = null;
    if (gold < 0) {
      try {
        reservationId = await holdGold(db, { userId, amount: -gold, key: grantId,
          description: changes.map((change) => change.title).join(", ").slice(0, 200) }, environment);
      } catch (error) {
        if (!(error instanceof NotEnoughGoldError)) throw error;
        if (input.price) {
          throw new ApiError(422, "PET_NOT_ENOUGH_GOLD", `This costs ${input.price} gold, and you have ${error.available}.`);
        }
        // Spent elsewhere since it was read: work the change out again from what is left.
        continue;
      }
    }
    let updated: boolean;
    try {
      updated = await db.transaction(async (tx) => {
        const written = await tx.update(userPets)
          .set({ ...input.set, statsJson: withoutGold(stats), ...(comfortDate ? { roomEffectDate: comfortDate } : {}) })
          .where(and(
            eq(userPets.userId, userId),
            eq(userPets.lifeId, input.lifeId),
            row.statsJson ? sql`${userPets.statsJson} = ${JSON.stringify(row.statsJson)}::jsonb` : isNull(userPets.statsJson),
            input.where,
          ))
          .returning({ userId: userPets.userId });
        if (!written.length) return false;
        if (daily || walk) {
          const paid = await tx.update(userWallets).set({
            walkGoldJson: walk?.ledger ?? wallet.walkGoldJson,
            dailyGoldDate: daily?.date ?? wallet.dailyGoldDate,
            version: wallet.version + 1,
            updatedAt: now,
          })
            .where(and(eq(userWallets.userId, userId), eq(userWallets.version, wallet.version)))
            .returning({ userId: userWallets.userId });
          if (!paid.length) throw new WalletConflict();
        }
        if (gold !== 0) {
          await tx.insert(userWalletGrants).values({ id: grantId, userId, kind: "pet", gold, reservationId,
            billingEnvironment: environment, createdAt: now });
        }
        return true;
      });
    } catch (error) {
      await releaseGold(reservationId, grantId, environment);
      if (error instanceof WalletConflict) continue;
      throw error;
    }
    if (!updated) {
      await releaseGold(reservationId, grantId, environment);
      continue;
    }
    if (gold !== 0) await carryGold(db, userId);
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
    // Whatever happened, the pet's memory agent reads it once the owner has their answer.
    queuePetMemory(db, userId, input.lifeId, lines.flatMap(({ change }, index) => isMemorable(change)
      ? [{ kind: change.kind, title: change.title, detail: change.detail, at: new Date(at + index).toISOString() }] : []));
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
