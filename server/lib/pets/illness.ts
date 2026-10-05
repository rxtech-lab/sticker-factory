import type { PetIllness } from "@/lib/db/schema";
import type { PetEffects } from "./stats";

/** What being ill costs the pet on every life-workflow visit until it is cured or gets over it. */
export const ILLNESS_EFFECTS: PetEffects = { happiness: -3, hp: -4, energy: -3, gold: 0 };
/** Left untreated, a pet gets over an illness on its own after this long. */
export const ILLNESS_RECOVERY_HOURS = 72;
/** What a dose of medicine does on top of curing: the pet perks up and gets some HP back. */
export const MEDICINE_EFFECTS: PetEffects = { happiness: 4, hp: 15, energy: 0, gold: 0 };
/** The chance any visit makes a well pet ill, before what the event and its HP add. */
const BASE_ILLNESS_CHANCE = 0.02;
/** A worn-down pet catches things: added to the chance below this share of its max HP. */
const LOW_HP_SHARE = 0.3;
const LOW_HP_ILLNESS_CHANCE = 0.12;

/** What a pet that falls ill without a named cause is ill with. */
export const ILLNESSES = ["a sniffly cold", "a tummy bug", "a fever", "the hiccups that won't stop", "a sore paw"] as const;

/**
 * The chance this visit makes a well pet ill: a little always, more when it is worn down, and an
 * event's own `sickens` on top (a soaking, a tummy ache).
 */
export function illnessChance(input: { hp: number; maxHp: number; eventSickens?: number }): number {
  const lowHp = input.hp < input.maxHp * LOW_HP_SHARE ? LOW_HP_ILLNESS_CHANCE : 0;
  return Math.min(0.9, BASE_ILLNESS_CHANCE + lowHp + (input.eventSickens ?? 0));
}

/** A new illness, named, starting now. `random` picks the name when none is given. */
export function catchIllness(now: Date, random: () => number, name?: string): PetIllness {
  return { name: name ?? ILLNESSES[Math.floor(random() * ILLNESSES.length) % ILLNESSES.length], since: now.toISOString() };
}

/** Whether a pet ill since `illness.since` has got over it on its own by `now`. */
export function hasRecovered(illness: PetIllness, now: Date): boolean {
  return now.getTime() - new Date(illness.since).getTime() >= ILLNESS_RECOVERY_HOURS * 3_600_000;
}
