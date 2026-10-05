import {
  PET_ITEM_RESTORE_ENERGY_MAX,
  PET_ITEM_RESTORE_ENERGY_MIN,
  PET_ITEM_RESTORE_PRICE_MAX,
  PET_ITEM_RESTORE_PRICE_MIN,
} from "@/lib/contracts/api";
import type { PetAction } from "@/lib/ai/gateway-contracts";

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, Math.round(value)));

/**
 * Holds a generated item set to its one expensive energy restorer: the item restoring the most
 * energy becomes it — 30 to 50 energy for 30 to 50 gold — and every other item stays within the
 * ordinary ±20 energy.
 * Ties go to the later item, so the agent's first pick stays an everyday one. Enforced here rather
 * than trusted to the agent, so a set that forgot one still has a way to wake a tired pet.
 */
export function withEnergyRestorer<Item extends Omit<PetAction, "id">>(items: Item[]): Item[] {
  if (items.length === 0) return items;
  const restorer = items.reduce((best, item, index) => item.effects.energy >= items[best].effects.energy ? index : best, 0);
  return items.map((item, index) => {
    if (index !== restorer) {
      return { ...item, effects: { ...item.effects, energy: Math.min(item.effects.energy, 20) } };
    }
    return {
      ...item,
      effects: {
        ...item.effects,
        energy: clamp(item.effects.energy, PET_ITEM_RESTORE_ENERGY_MIN, PET_ITEM_RESTORE_ENERGY_MAX),
        gold: -clamp(-Math.min(0, item.effects.gold), PET_ITEM_RESTORE_PRICE_MIN, PET_ITEM_RESTORE_PRICE_MAX),
      },
    };
  });
}
