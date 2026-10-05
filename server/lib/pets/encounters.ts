import { createHash } from "node:crypto";
import type { PetEncounterChoice } from "@/lib/db/schema";
import { localDate, localHour } from "./signals";

/** The earliest and latest local hour a day's encounter may happen at, so nobody is woken by one. */
export const ENCOUNTER_FIRST_HOUR = 9;
export const ENCOUNTER_LAST_HOUR = 20;
/** How long the owner has to answer before the moment passes. */
export const ENCOUNTER_LIFETIME_MS = 12 * 60 * 60 * 1000;

/** The most a right choice may reward, and a wrong one cost. */
export const ENCOUNTER_REWARD_MAX = { happiness: 15, hp: 15, energy: 20, gold: 25 } as const;
export const ENCOUNTER_PENALTY_MAX = { happiness: 15, hp: 15, energy: 15, gold: 10 } as const;

/**
 * The local hour today's encounter is due from: picked at random per pet and day, but the same on
 * every visit that day, so the moment lands somewhere new each day without being rolled twice.
 */
export function encounterHour(userId: string, lifeId: string, date: string): number {
  const digest = createHash("sha256").update(`${userId}|${lifeId}|${date}`).digest();
  return ENCOUNTER_FIRST_HOUR + (digest[0] % (ENCOUNTER_LAST_HOUR - ENCOUNTER_FIRST_HOUR + 1));
}

/**
 * The local date an encounter would be for if one is due now, or null: once the day's hour has come,
 * and before the evening is out. Whether today already had one is the caller's to check.
 * `PET_ENCOUNTER_ANY_HOUR=1` lets one happen at any hour, for debugging the flow end to end.
 */
export function encounterDueDate(userId: string, lifeId: string, now: Date, timeZone: string | undefined): string | null {
  const date = localDate(now, timeZone);
  if (process.env.PET_ENCOUNTER_ANY_HOUR === "1") return date;
  const hour = localHour(now, timeZone);
  if (hour > ENCOUNTER_LAST_HOUR + 1) return null;
  return hour >= encounterHour(userId, lifeId, date) ? date : null;
}

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, Math.round(value)));

/**
 * Holds what the agent wrote to the rules: a right choice never costs the pet anything nor makes
 * it ill, and a wrong one never rewards it or hands out medicine. Whatever the agent got backwards
 * is turned around rather than refused, so a slightly-off answer still makes a fair encounter.
 */
export function sanitizeChoice(choice: Omit<PetEncounterChoice, "id">): Omit<PetEncounterChoice, "id"> {
  const { effects } = choice;
  if (choice.correct) {
    const up = ENCOUNTER_REWARD_MAX;
    return {
      ...choice,
      effects: {
        happiness: clamp(Math.abs(effects.happiness), 0, up.happiness),
        hp: clamp(Math.abs(effects.hp), 0, up.hp),
        energy: clamp(Math.abs(effects.energy), 0, up.energy),
        gold: clamp(Math.abs(effects.gold), 0, up.gold),
      },
      medicine: clamp(choice.medicine, 0, 1),
      sickens: false,
    };
  }
  const down = ENCOUNTER_PENALTY_MAX;
  const penalized = {
    happiness: -clamp(Math.abs(effects.happiness), 0, down.happiness),
    hp: -clamp(Math.abs(effects.hp), 0, down.hp),
    energy: -clamp(Math.abs(effects.energy), 0, down.energy),
    gold: -clamp(Math.abs(effects.gold), 0, down.gold),
  };
  // A wrong choice always stings a little, even when the agent forgot to say how.
  if (!choice.sickens && Object.values(penalized).every((value) => value === 0)) penalized.happiness = -5;
  return { ...choice, effects: penalized, medicine: 0 };
}
