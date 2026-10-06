import { createHash } from "node:crypto";
import {
  PET_ITEM_KEEP_HOURS_MAX,
  PET_ITEM_KEEP_HOURS_MIN,
  PET_ITEM_RESTORE_ENERGY_MAX,
  PET_ITEM_RESTORE_ENERGY_MIN,
  PET_ITEM_RESTORE_PRICE_MAX,
  PET_ITEM_RESTORE_PRICE_MIN,
  PET_ITEM_SHELF_HOURS_MAX,
  PET_ITEM_SHELF_HOURS_MIN,
} from "@/lib/contracts/api";
import type { PetAction } from "@/lib/ai/gateway-contracts";
import type { PetBagUnit } from "@/lib/db/schema";

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, Math.round(value)));
const HOUR_MS = 60 * 60 * 1000;

/** The items still on the shelf at `now`. Items stocked before items left the shelf stay. */
export function liveShelf(items: PetAction[] | null | undefined, now: Date): PetAction[] {
  return (items ?? []).filter((item) => !item.leavesAt || new Date(item.leavesAt) > now);
}

/** The things in the bag that have not expired by `now`. */
export function liveBag(units: PetBagUnit[], now: Date): PetBagUnit[] {
  return units.filter((unit) => !unit.expiresAt || new Date(unit.expiresAt) > now);
}

/**
 * The bag as the owner sees it: one entry per item, in the order first bought, with how many there
 * are and when the first of them expires.
 */
export function groupBag(units: PetBagUnit[]): { item: PetAction; count: number; expiresAt: string | null }[] {
  const groups = new Map<string, { item: PetAction; count: number; expiresAt: string | null }>();
  for (const unit of units) {
    const group = groups.get(unit.item.id);
    if (!group) {
      groups.set(unit.item.id, { item: unit.item, count: 1, expiresAt: unit.expiresAt });
      continue;
    }
    group.count += 1;
    if (unit.expiresAt && (!group.expiresAt || unit.expiresAt < group.expiresAt)) group.expiresAt = unit.expiresAt;
  }
  return [...groups.values()];
}

/** The one of `item` in the bag to use next: the one expiring soonest, then the oldest. */
export function nextBagUnit(units: PetBagUnit[], itemId: string): PetBagUnit | undefined {
  return units.filter((unit) => unit.item.id === itemId)
    .sort((a, b) => (a.expiresAt ?? "~").localeCompare(b.expiresAt ?? "~") || a.boughtAt.localeCompare(b.boughtAt))[0];
}

/** Names what is on the shelf, as a UUID, so a client sees it change whenever the shelf does. */
export function shopVersion(items: PetAction[]): string {
  const hex = createHash("sha256").update(items.map((item) => item.id).join("|")).digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

/** When an item the agent stocked leaves the shelf, held to the shop's bounds. */
export function leavesAt(shelfHours: number, now: Date): string {
  return new Date(now.getTime() + clamp(shelfHours, PET_ITEM_SHELF_HOURS_MIN, PET_ITEM_SHELF_HOURS_MAX) * HOUR_MS).toISOString();
}

/** How long an item keeps once bought, held to the bag's bounds; null when it never expires. */
export function keepsHours(hours: number | null): number | null {
  return hours === null ? null : clamp(hours, PET_ITEM_KEEP_HOURS_MIN, PET_ITEM_KEEP_HOURS_MAX);
}

/** When one bought at `now` expires, or null when it never does. */
export function expiresAt(item: Pick<PetAction, "keepsHours">, now: Date): string | null {
  return item.keepsHours ? new Date(now.getTime() + item.keepsHours * HOUR_MS).toISOString() : null;
}

/** What items stocked before they had lifetimes get, by kind: food spoils, tickets lapse, toys last. */
export function legacyKeepsHours(kind: PetAction["kind"]): number | null {
  return kind === "food" ? 48 : kind === "ticket" ? 168 : null;
}

/**
 * Holds a generated item set to its one expensive energy restorer: the item restoring the most
 * energy becomes it — 30 to 50 energy for 30 to 50 gold — and every other item stays within the
 * ordinary ±20 energy.
 * Ties go to the later item, so the agent's first pick stays an everyday one. Enforced here rather
 * than trusted to the agent, so a set that forgot one still has a way to wake a tired pet.
 *
 * `kept` are items already in the shop: when one of them is the restorer, the new items are all
 * everyday ones.
 */
export function withEnergyRestorer<Item extends Omit<PetAction, "id">>(items: Item[], kept: Omit<PetAction, "id">[] = []): Item[] {
  if (items.length === 0) return items;
  if (kept.some((item) => item.effects.energy > 20)) {
    return items.map((item) => ({ ...item, effects: { ...item.effects, energy: Math.min(item.effects.energy, 20) } }));
  }
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
