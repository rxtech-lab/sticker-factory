import { and, eq, isNotNull, isNull, lt, or } from "drizzle-orm";
import { start } from "workflow/api";
import type { Database } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { petLifeWorkflow } from "@/workflows/pet-life";

type LifeStarter = (userId: string, lifeId: string, token: string) => Promise<string>;
let starterForTests: LifeStarter | undefined;

/** Tests run no workflow runtime; they install a starter to see what would have been started. */
export function setPetLifeStarterForTests(starter: LifeStarter | undefined): void {
  starterForTests = starter;
}

/**
 * Starts the durable workflow that visits this pet every few hours.
 *
 * A fresh token is written first and handed to the run: whichever run holds the token on the row
 * is the pet's one living workflow, and any older run ends the next time it wakes. That makes a
 * restart safe at any moment — after a new adoption, from the cron's revival, twice in a row.
 * Never throws: a pet without a workflow is still a pet, and the cron will try again.
 */
export async function startPetLife(db: Database, userId: string, lifeId: string): Promise<void> {
  const token = crypto.randomUUID();
  try {
    const claimed = await db.update(userPets).set({ lifeRunId: token })
      .where(and(eq(userPets.userId, userId), eq(userPets.lifeId, lifeId)))
      .returning({ userId: userPets.userId });
    if (!claimed.length) return;
    let runId: string;
    if (starterForTests) runId = await starterForTests(userId, lifeId, token);
    else if (process.env.NODE_ENV === "test") runId = "test-skipped";
    else runId = (await start(petLifeWorkflow, [userId, lifeId, token])).runId;
    petLog("life:started", { userId, lifeId, token, runId });
  } catch (error) {
    petLog("life:start-failed", { userId, lifeId, error: describeError(error) });
    // Released, so the next getPet or cron revival tries again instead of waiting on a dead token.
    await db.update(userPets).set({ lifeRunId: null })
      .where(and(eq(userPets.userId, userId), eq(userPets.lifeRunId, token)))
      .catch(() => undefined);
  }
}

/** A visit this overdue means the workflow holding the token is gone. */
const STALLED_AFTER_MS = 2 * 60 * 60 * 1000;

/**
 * Restarts the life of every pet whose workflow has ended or stalled. Run by the hourly cron, so
 * a deploy that dropped runs, or a pet whose workflow retired after its week, is back within an hour.
 */
export async function revivePetLives(db: Database, now = new Date(), limit = 100): Promise<{ revived: number }> {
  const stalled = await db.select({ userId: userPets.userId, lifeId: userPets.lifeId }).from(userPets)
    .where(and(isNotNull(userPets.lifeId), or(
      isNull(userPets.lifeRunId),
      lt(userPets.nextEventAt, new Date(now.getTime() - STALLED_AFTER_MS)),
    )))
    .limit(limit);
  for (const pet of stalled) await startPetLife(db, pet.userId, pet.lifeId!);
  petLog("life:revived", { count: stalled.length });
  return { revived: stalled.length };
}
