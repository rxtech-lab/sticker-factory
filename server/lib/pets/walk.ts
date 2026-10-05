import type { PetWalkGold, UserPetRow } from "@/lib/db/schema";
import { localDate, stepsToday } from "./signals";

/** Gold is mostly earned by walking: one coin for every this many steps the owner takes. */
export const STEPS_PER_GOLD = 250;
/**
 * A phone reporting new steps pays them out on its own only once they add up to this much, so a
 * walk reads as a few diary lines rather than one per refresh. Any other change pays whatever is due.
 */
export const WALK_PAYOUT_MIN_GOLD = 10;

/**
 * The gold the owner's walk has earned today and not yet been paid, with the ledger to store once
 * it is. Steps a phone later corrects downward are never taken back.
 */
export function walkReward(row: Pick<UserPetRow, "contextJson" | "walkGoldJson">, now: Date): { gold: number; steps: number; ledger: PetWalkGold } | null {
  const steps = stepsToday(row.contextJson, now);
  if (steps === null) return null;
  const date = localDate(now, row.contextJson?.timeZone);
  const paid = row.walkGoldJson?.date === date ? row.walkGoldJson.steps : 0;
  const gold = Math.floor(steps / STEPS_PER_GOLD) - Math.floor(paid / STEPS_PER_GOLD);
  if (gold <= 0) return null;
  return { gold, steps, ledger: { date, steps } };
}
