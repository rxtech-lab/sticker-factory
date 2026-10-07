// How the pet feels, in words: what its pose is chosen to show, and what tells a stored pose is stale.

/**
 * How the pet feels from its stats, in words the decision model can weigh: the same thresholds the
 * app's `PetMood` reads its body from — sick under 30% HP, sleepy under 25 energy, grumpy under 35
 * happiness, joyful from 75.
 */
export function describeCondition(stats: { happiness: number; energy: number; hp: number }, maxHp: number, illness?: string | null): string {
  const feelings: string[] = [];
  if (illness) feelings.push(`ill with ${illness}`);
  else if (stats.hp < Math.max(maxHp, 1) * 0.3) feelings.push("unwell and fragile");
  if (stats.energy < 25) feelings.push("exhausted and sleepy");
  else if (stats.energy < 50) feelings.push("a little tired");
  else if (stats.energy >= 80) feelings.push("full of energy");
  if (stats.happiness < 35) feelings.push("unhappy and grumpy");
  else if (stats.happiness >= 75) feelings.push("joyful");
  else feelings.push("content");
  return feelings.join(", ");
}
