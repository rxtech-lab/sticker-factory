import type { PetStoredContext, PetWalkGold } from "@/lib/db/schema";
import { localDate, stepsToday } from "./signals";

/** Gold is mostly earned by walking: one coin for every this many steps the owner takes. */
export const STEPS_PER_GOLD = 250;
/** Walking the pet is how it gets its energy back: one point for every this many steps. */
export const STEPS_PER_ENERGY = 100;
/**
 * A phone reporting new steps pays them out on its own only once they add up to this much gold or
 * energy, so a walk reads as a few diary lines rather than one per refresh. Any other change pays
 * whatever is due.
 */
export const WALK_PAYOUT_MIN_GOLD = 10;
export const WALK_PAYOUT_MIN_ENERGY = 10;

export type WalkReward = { gold: number; energy: number; steps: number; ledger: PetWalkGold };

/**
 * The gold and energy the owner's walk has earned today and not yet been paid, with the ledger to
 * store once it is. Steps a phone later corrects downward are never taken back. Energy is owed
 * even when the pet is already full; it simply tops out there.
 */
export function walkReward(
  row: { contextJson: PetStoredContext | null; walkGoldJson: PetWalkGold | null },
  now: Date,
): WalkReward | null {
  const steps = stepsToday(row.contextJson, now);
  if (steps === null) return null;
  const date = localDate(now, row.contextJson?.timeZone);
  const paid = row.walkGoldJson?.date === date ? row.walkGoldJson.steps : 0;
  if (steps <= paid) return null;
  const owed = (per: number) => Math.floor(steps / per) - Math.floor(paid / per);
  const gold = owed(STEPS_PER_GOLD);
  const energy = owed(STEPS_PER_ENERGY);
  if (gold <= 0 && energy <= 0) return null;
  return { gold, energy, steps, ledger: { date, steps } };
}

/** Whether `walk` is worth paying out the moment the phone reports it. */
export function isWalkPayoutDue(walk: WalkReward | null): walk is WalkReward {
  return !!walk && (walk.gold >= WALK_PAYOUT_MIN_GOLD || walk.energy >= WALK_PAYOUT_MIN_ENERGY);
}

/** The diary line for a walk paid out. */
export function walkDetail(walk: Pick<WalkReward, "gold" | "energy" | "steps">): string {
  const earned = [
    walk.energy > 0 ? `restored ${walk.energy} energy` : null,
    walk.gold > 0 ? `earned ${walk.gold} gold` : null,
  ].filter(Boolean).join(" and ");
  return `${walk.steps.toLocaleString("en-US")} steps today ${earned}.`;
}
