import { eq } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { generationJobs, petEvents, stickers, userPets, userWalletGrants } from "@/lib/db/schema";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { initialStats, withoutGold } from "@/lib/pets/stats";
import { goldBalance, goldEnvironment } from "@/lib/subscription/gold";
import { ensureWallet } from "./pet-state";

/** The gold the owner earns for every sticker one of their turns makes, pet or no pet. */
export const STICKER_GOLD = 20;

/** The turns that leave a sticker behind. Plans, exports and cleanups make nothing. */
const GOLD_JOB_KINDS = new Set(["image", "edit", "animation", "chat", "compose"]);

/**
 * Pays the owner for a sticker their turn just made, into the purse every pet of theirs shares,
 * and notes it in the current pet's diary. Paid once per turn however often the step runs: the
 * grant is queued under the turn's id and carried to RxSubscription under it.
 *
 * Runs as a step after the turn has completed. Never throws: the sticker is made either way.
 */
export async function grantStickerGold(
  db: Database,
  jobId: string,
  revisionId: string | undefined,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<void> {
  try {
    if (!revisionId) return;
    const job = await db.select({ ownerId: generationJobs.ownerId, origin: generationJobs.origin, state: generationJobs.state,
      kind: generationJobs.kind, billingEnvironment: generationJobs.billingEnvironment, title: stickers.title })
      .from(generationJobs)
      .innerJoin(stickers, eq(stickers.id, generationJobs.stickerId))
      .where(eq(generationJobs.id, jobId))
      .then(firstRow);
    // The pet's own growth is not the owner's work.
    if (!job || job.origin !== "user" || job.state !== "succeeded" || !GOLD_JOB_KINDS.has(job.kind)) return;
    const userId = job.ownerId;
    // A wallet opened here starts like one opened with a pet: the starting purse is today's gold.
    await ensureWallet(db, userId, undefined);
    // The turn knows where its points were billed; its gold goes beside them.
    const environment = job.billingEnvironment ?? await goldEnvironment(db, userId);
    const now = new Date();
    const granted = await db.insert(userWalletGrants)
      .values({ id: `sticker:${jobId}`, userId, kind: "sticker", gold: STICKER_GOLD, billingEnvironment: environment, createdAt: now })
      .onConflictDoNothing()
      .returning({ id: userWalletGrants.id });
    if (!granted.length) return;
    const gold = await goldBalance(db, userId, environment);
    const pet = await db.select().from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
    if (pet?.lifeId) {
      const stats = withoutGold(pet.statsJson ?? initialStats(pet.identityJson));
      await db.insert(petEvents).values({
        id: crypto.randomUUID(), userId, lifeId: pet.lifeId, stickerId: pet.stickerId, kind: "special",
        title: "Sticker reward",
        detail: `Earned ${STICKER_GOLD} gold for making “${job.title}”.`.slice(0, 400),
        effectsJson: { happiness: 0, hp: 0, energy: 0, gold: STICKER_GOLD },
        statsBeforeJson: { ...stats, gold: Math.max(0, gold - STICKER_GOLD) },
        statsAfterJson: { ...stats, gold },
        debugJson: { source: "sticker-gold", jobId, revisionId },
        createdAt: now,
      });
    }
    petLog("gold:sticker", { userId, jobId, gold: STICKER_GOLD, balance: gold });
    if (pet) await notify(db, userId);
  } catch (error) {
    petLog("gold:sticker-failed", { jobId, error: describeError(error) });
  }
}
