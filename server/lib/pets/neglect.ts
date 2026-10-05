import type { PetEffects } from "./stats";

/** The diary kinds that mean the owner spent time with the pet. Visits, walks and growing do not. */
export const ATTENTION_KINDS = ["adopted", "send", "interaction", "share", "photo", "sticker", "encounter", "medicine"] as const;

/** How long a pet can go unattended before it starts to pine. */
export const NEGLECT_GRACE_HOURS = 12;

/** Each visit's toll on a pet left alone, worsening the longer its owner stays away. */
const NEGLECT_TIERS: Array<{ fromHours: number; happiness: number; hp: number }> = [
  { fromHours: 72, happiness: -8, hp: -5 },
  { fromHours: 24, happiness: -6, hp: -3 },
  { fromHours: NEGLECT_GRACE_HOURS, happiness: -4, hp: -2 },
];

/** What one visit costs a pet whose owner was last around `hoursAway` hours ago, or null if it is not missing them yet. */
export function neglectEffects(hoursAway: number): PetEffects | null {
  const tier = NEGLECT_TIERS.find((candidate) => hoursAway >= candidate.fromHours);
  return tier ? { happiness: tier.happiness, hp: tier.hp, energy: 0, gold: 0 } : null;
}

/**
 * A neglected pet does not cheer up on its own: whatever else a visit brings, its happiness and HP
 * drop by at least the neglect toll.
 */
export function withNeglect(effects: PetEffects, neglect: PetEffects | null): PetEffects {
  if (!neglect) return effects;
  return {
    ...effects,
    happiness: Math.min(effects.happiness + neglect.happiness, neglect.happiness),
    hp: Math.min(effects.hp + neglect.hp, neglect.hp),
  };
}

/** The diary's note on how long the owner has been gone. */
export function neglectNote(hoursAway: number): string {
  const days = Math.floor(hoursAway / 24);
  const away = days >= 1 ? `${days} day${days === 1 ? "" : "s"}` : `${Math.floor(hoursAway)} hours`;
  return `Hasn't seen you in ${away}.`;
}
