import { and, desc, eq, isNull, lt, or, sql, type SQL } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetEventV1, PetSignalsV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petEvents, userPets, type PetStatsValues, type UserPetRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { buildIdentity, fallbackIdentity } from "@/lib/pets/identity";
import { petLog, petRandom } from "@/lib/pets/log";
import { EMPTY_SIGNALS } from "@/lib/pets/signals";
import { applyEffects, initialStats, withGold, type PetEffects, type PetStats } from "@/lib/pets/stats";
import { walkReward } from "@/lib/pets/walk";
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

export async function petRow(db: Database, userId: string): Promise<UserPetRow | undefined> {
  return db.select().from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
}

export function currentStats(row: UserPetRow): PetStats {
  return row.statsJson ? withGold(row.statsJson) : initialStats(row.identityJson);
}

/**
 * Applies `changes` to the pet's stats in order and writes a diary line for each.
 *
 * The stats are read, changed and written back only if nobody else wrote them meanwhile — a send
 * being read while the owner taps an action must not lose either one — so the slow part (asking a
 * model) happens before this, and this only re-adds deltas. Null when the pet stopped being this
 * life, or `where` no longer holds.
 *
 * Gold the owner's walk has earned since it was last paid lands first, as its own line, worked
 * out again on every attempt so a retried write never pays the same steps twice.
 */
export async function commitPetChange(
  db: Database,
  userId: string,
  input: { lifeId: string; changes: PetChange[]; set?: Partial<typeof userPets.$inferInsert>; where?: SQL },
): Promise<{ before: PetStatsValues; after: PetStatsValues } | null> {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const row = await petRow(db, userId);
    if (!row || row.lifeId !== input.lifeId) return null;
    const before = currentStats(row);
    let stats = before;
    const walk = walkReward(row, new Date());
    const changes: PetChange[] = walk ? [{
      kind: "special",
      title: "Walk reward",
      detail: `${walk.steps.toLocaleString("en-US")} steps today earned ${walk.gold} gold.`,
      effects: { happiness: 0, hp: 0, energy: 0, gold: walk.gold },
      debug: { source: "walk", steps: walk.steps, paidBefore: row.walkGoldJson ?? null },
    }, ...input.changes] : input.changes;
    const lines = changes.map((change) => {
      const statsBefore = stats;
      stats = applyEffects(stats, change.effects, row.identityJson);
      return { change, statsBefore, statsAfter: stats };
    });
    const updated = await db.update(userPets).set({ ...input.set, statsJson: stats, ...(walk ? { walkGoldJson: walk.ledger } : {}) })
      .where(and(
        eq(userPets.userId, userId),
        eq(userPets.lifeId, input.lifeId),
        row.statsJson ? sql`${userPets.statsJson} = ${JSON.stringify(row.statsJson)}::jsonb` : isNull(userPets.statsJson),
        input.where,
      ))
      .returning({ userId: userPets.userId });
    if (!updated.length) continue;
    const now = Date.now();
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
        createdAt: new Date(now + index),
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
  row: UserPetRow,
  describe: () => Promise<{ title: string; controls: StickerControl[]; image: AiReferenceImage | null }>,
): Promise<UserPetRow> {
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
