import { createHash } from "node:crypto";
import { PET_CLASSES, PET_WEATHER_KINDS, type PetIdentityV1, type PetSignalsV1 } from "@/lib/contracts/api";

export type PetClass = (typeof PET_CLASSES)[number];
export type PetWeatherKind = (typeof PET_WEATHER_KINDS)[number];

/**
 * What each class is made of. The model chooses the class and writes the personality; the numbers
 * come from here, so no pet can be talked into 200 HP and free energy.
 *
 * Explorer is the balanced one — 100 HP, every activity at face value — and is what a pet whose
 * identity could not be generated becomes.
 */
export const PET_CLASS_TRAITS: Record<PetClass, { maxHp: number; energyMultiplier: number; summary: string }> = {
  guardian: { maxHp: 140, energyMultiplier: 0.9, summary: "sturdy and protective; slow to tire, hard to hurt" },
  explorer: { maxHp: 100, energyMultiplier: 1, summary: "curious and outdoorsy; loves walks and new places" },
  dreamer: { maxHp: 90, energyMultiplier: 1.3, summary: "gentle and sleepy; tires fast, loves naps and quiet skies" },
  trickster: { maxHp: 85, energyMultiplier: 1.15, summary: "playful and mischievous; thrives on chaos and friends" },
  scholar: { maxHp: 100, energyMultiplier: 0.75, summary: "thoughtful and calm; follows the news, rarely runs out of steam" },
  athlete: { maxHp: 125, energyMultiplier: 1.5, summary: "energetic and tough; burns energy fast, loves a long walk" },
};

/** What the model decides about a new pet. */
export type PetPersona = {
  class: PetClass;
  personality: string;
  likes: string[];
  dislikes: string[];
  favoriteWeather: PetWeatherKind;
};

/**
 * Turns a persona into a full identity. `random` adds a little individuality — two guardians are
 * not identical — within ±8 HP and ±0.1 energy multiplier of the class.
 */
export function buildIdentity(persona: PetPersona, birth: PetSignalsV1, at: Date, random: () => number): PetIdentityV1 {
  const traits = PET_CLASS_TRAITS[persona.class];
  const jitter = () => random() * 2 - 1;
  const maxHp = Math.round(Math.min(200, Math.max(50, traits.maxHp + jitter() * 8)));
  const energyMultiplier = Math.round(Math.min(2, Math.max(0.5, traits.energyMultiplier + jitter() * 0.1)) * 100) / 100;
  return {
    class: persona.class,
    personality: persona.personality.trim().slice(0, 80) || "Friendly",
    likes: persona.likes.map((like) => like.trim().slice(0, 32)).filter(Boolean).slice(0, 4),
    dislikes: persona.dislikes.map((dislike) => dislike.trim().slice(0, 32)).filter(Boolean).slice(0, 4),
    favoriteWeather: persona.favoriteWeather,
    maxHp,
    energyMultiplier,
    birth: { ...birth, at: at.toISOString() },
  };
}

/**
 * The identity a pet gets when the model could not write one: a balanced explorer whose favourite
 * weather is picked from its sticker id, so the same sticker always comes out the same.
 */
export function fallbackIdentity(stickerId: string, birth: PetSignalsV1, at: Date): PetIdentityV1 {
  const byte = createHash("sha256").update(stickerId).digest()[0];
  return buildIdentity({
    class: "explorer",
    personality: "Friendly and curious",
    likes: ["walks", "sunshine"],
    dislikes: ["thunder"],
    favoriteWeather: PET_WEATHER_KINDS[byte % PET_WEATHER_KINDS.length],
  }, birth, at, () => 0.5);
}
