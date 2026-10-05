import type { PetStoredContext } from "@/lib/db/schema";
import { localDate } from "./signals";

/** How many rooms the shop offers at once, and how long until it offers new ones. */
export const ROOM_OFFER_COUNT = 3;
export const ROOM_OFFER_LIFETIME_MS = 24 * 60 * 60 * 1000;

/** The most a room may change one stat by, each day the pet lives in it. */
export const ROOM_EFFECT_MAX = 8;
export const ROOM_EFFECT_MIN = -5;
/** What a room may cost: never cheap, never more than a few weeks of walking. */
export const ROOM_PRICE_MIN = 40;
export const ROOM_PRICE_MAX = 300;

export type RoomEffects = { happiness: number; hp: number; energy: number };

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, Math.round(value)));

/** The fair price range for a room, from how much good it does a day. */
export function roomPriceRange(effects: RoomEffects): { min: number; max: number } {
  const good = Math.max(0, effects.happiness) + Math.max(0, effects.hp) + Math.max(0, effects.energy);
  return {
    min: Math.max(ROOM_PRICE_MIN, 25 + 8 * good),
    max: Math.min(ROOM_PRICE_MAX, 80 + 20 * good),
  };
}

/**
 * Holds what the agent wrote to the rules: each stat within bounds, every room good for something,
 * and a price that matches how good it is. A room that does nothing gets a little comfort rather
 * than being refused, and a price off the scale is moved onto it.
 */
export function sanitizeRoom<Room extends { effects: RoomEffects; price: number }>(room: Room): Room {
  const effects = {
    happiness: clamp(room.effects.happiness, ROOM_EFFECT_MIN, ROOM_EFFECT_MAX),
    hp: clamp(room.effects.hp, ROOM_EFFECT_MIN, ROOM_EFFECT_MAX),
    energy: clamp(room.effects.energy, ROOM_EFFECT_MIN, ROOM_EFFECT_MAX),
  };
  if (effects.happiness <= 0 && effects.hp <= 0 && effects.energy <= 0) effects.happiness = 2;
  const { min, max } = roomPriceRange(effects);
  return { ...room, effects, price: clamp(room.price, min, max) };
}

/**
 * The local date the pet's room would comfort it on, if it has not yet today, or null. A pet that
 * moves rooms the same day waits until tomorrow for the new one: the comfort is the pet's, once a day.
 */
export function roomComfortDate(
  context: Pick<PetStoredContext, "timeZone"> | null,
  lastDate: string | null,
  now: Date,
): string | null {
  const date = localDate(now, context?.timeZone);
  return lastDate === date ? null : date;
}

/** "+4 happiness, −2 energy" for a diary line. */
export function describeRoomEffects(effects: RoomEffects): string {
  return (["happiness", "hp", "energy"] as const)
    .filter((stat) => effects[stat] !== 0)
    .map((stat) => `${effects[stat] > 0 ? "+" : "−"}${Math.abs(effects[stat])} ${stat === "hp" ? "HP" : stat}`)
    .join(", ");
}
