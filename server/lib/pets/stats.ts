import type { PetIdentityV1 } from "@/lib/contracts/api";
import type { PetStatsValues } from "@/lib/db/schema";

export type PetEffects = PetStatsValues;
/** A pet's stats as read: every one present, gold included. */
export type PetStats = Required<PetStatsValues>;

export const ZERO_EFFECTS: PetEffects = { happiness: 0, hp: 0, energy: 0, gold: 0 };

/** What a new owner has to spend before their first walk or daily allowance. */
export const STARTING_GOLD = 20;

/** Stats for a pet that has just arrived: content, at full health, a little short of full energy. */
export function initialStats(identity: Pick<PetIdentityV1, "maxHp"> | null): PetStats {
  return { happiness: 80, hp: identity?.maxHp ?? 100, energy: 80, gold: STARTING_GOLD };
}

/** Stored stats with gold filled in, for rows written before there was any. */
export function withGold(stats: PetStatsValues, gold = STARTING_GOLD): PetStats {
  return { ...stats, gold: stats.gold ?? gold };
}

/** A pet's own stats, without gold: gold is the owner's, kept in their wallet. */
export function withoutGold(stats: PetStatsValues): Omit<PetStatsValues, "gold"> {
  return { happiness: stats.happiness, hp: stats.hp, energy: stats.energy };
}

export function addEffects(...all: PetEffects[]): PetEffects {
  return all.reduce((sum, effects) => ({
    happiness: sum.happiness + effects.happiness,
    hp: sum.hp + effects.hp,
    energy: sum.energy + effects.energy,
    gold: (sum.gold ?? 0) + (effects.gold ?? 0),
  }), ZERO_EFFECTS);
}

/**
 * How `effects` land on a pet with this identity: an energy *cost* is scaled by its multiplier
 * (resting is not — a tired athlete recovers as fast as anyone), and HP tops out at its own max.
 */
export function personalizeEffects(effects: PetEffects, identity: PetIdentityV1 | null): PetEffects {
  const multiplier = identity?.energyMultiplier ?? 1;
  return {
    happiness: effects.happiness,
    hp: effects.hp,
    energy: effects.energy < 0 ? Math.round(effects.energy * multiplier) : effects.energy,
    gold: effects.gold ?? 0,
  };
}

/** Gold never goes below zero and has no ceiling; spending more than the owner has is refused before this. */
export function applyEffects(stats: PetStatsValues, effects: PetEffects, identity: PetIdentityV1 | null): PetStats {
  const clamp = (value: number, max: number) => Math.max(0, Math.min(max, value));
  return {
    happiness: clamp(stats.happiness + effects.happiness, 100),
    hp: clamp(stats.hp + effects.hp, identity?.maxHp ?? 100),
    energy: clamp(stats.energy + effects.energy, 100),
    gold: Math.max(0, withGold(stats).gold + (effects.gold ?? 0)),
  };
}

/**
 * A small bonus or penalty when something touches what the pet likes or dislikes. Matched by word,
 * case-insensitively, against free text — an action's title, an event's description.
 */
export function preferenceEffects(text: string, identity: PetIdentityV1 | null): { effects: PetEffects; matched: string[] } {
  if (!identity) return { effects: ZERO_EFFECTS, matched: [] };
  const haystack = text.toLocaleLowerCase();
  const liked = identity.likes.filter((like) => like && haystack.includes(like.toLocaleLowerCase()));
  const disliked = identity.dislikes.filter((dislike) => dislike && haystack.includes(dislike.toLocaleLowerCase()));
  return {
    effects: { happiness: liked.length * 4 - disliked.length * 5, hp: 0, energy: 0, gold: 0 },
    matched: [...liked.map((like) => `+${like}`), ...disliked.map((dislike) => `-${dislike}`)],
  };
}
