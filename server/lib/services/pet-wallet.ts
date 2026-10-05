import { eq, sql } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { generationJobs, petEvents, stickers, userPets, userWalletGrants, userWallets } from "@/lib/db/schema";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { localDate } from "@/lib/pets/signals";
import { initialStats, STARTING_GOLD, withoutGold } from "@/lib/pets/stats";

/** The gold the owner earns for every sticker one of their turns makes, pet or no pet. */
export const STICKER_GOLD = 20;

/** The turns that leave a sticker behind. Plans, exports and cleanups make nothing. */
const GOLD_JOB_KINDS = new Set(["image", "edit", "animation", "chat", "compose"]);

/**
 * Pays the owner for a sticker their turn just made, into the wallet every pet of theirs shares,
 * and notes it in the current pet's diary. Paid once per turn however often the step runs.
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
      kind: generationJobs.kind, title: stickers.title })
      .from(generationJobs)
      .innerJoin(stickers, eq(stickers.id, generationJobs.stickerId))
      .where(eq(generationJobs.id, jobId))
      .then(firstRow);
    // The pet's own growth is not the owner's work.
    if (!job || job.origin !== "user" || job.state !== "succeeded" || !GOLD_JOB_KINDS.has(job.kind)) return;
    const userId = job.ownerId;
    const now = new Date();
    const paid = await db.transaction(async (tx) => {
      const granted = await tx.insert(userWalletGrants)
        .values({ id: `sticker:${jobId}`, userId, kind: "sticker", gold: STICKER_GOLD, createdAt: now })
        .onConflictDoNothing()
        .returning({ id: userWalletGrants.id });
      if (!granted.length) return null;
      const [wallet] = await tx.insert(userWallets)
        // A wallet opened here starts like one opened with a pet: the starting purse is today's gold.
        .values({ userId, gold: STARTING_GOLD + STICKER_GOLD, dailyGoldDate: localDate(now, undefined), createdAt: now, updatedAt: now })
        .onConflictDoUpdate({
          target: userWallets.userId,
          set: { gold: sql`${userWallets.gold} + ${STICKER_GOLD}`, version: sql`${userWallets.version} + 1`, updatedAt: now },
        })
        .returning({ gold: userWallets.gold });
      const pet = await tx.select().from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
      if (pet?.lifeId) {
        const stats = withoutGold(pet.statsJson ?? initialStats(pet.identityJson));
        await tx.insert(petEvents).values({
          id: crypto.randomUUID(), userId, lifeId: pet.lifeId, stickerId: pet.stickerId, kind: "special",
          title: "Sticker reward",
          detail: `Earned ${STICKER_GOLD} gold for making “${job.title}”.`.slice(0, 400),
          effectsJson: { happiness: 0, hp: 0, energy: 0, gold: STICKER_GOLD },
          statsBeforeJson: { ...stats, gold: wallet.gold - STICKER_GOLD },
          statsAfterJson: { ...stats, gold: wallet.gold },
          debugJson: { source: "sticker-gold", jobId, revisionId },
          createdAt: now,
        });
      }
      return { gold: wallet.gold, hasPet: !!pet };
    });
    if (!paid) return;
    petLog("gold:sticker", { userId, jobId, gold: STICKER_GOLD, balance: paid.gold });
    if (paid.hasPet) await notify(db, userId);
  } catch (error) {
    petLog("gold:sticker-failed", { jobId, error: describeError(error) });
  }
}

