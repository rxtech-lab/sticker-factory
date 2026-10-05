import { describe, expect, it } from "vitest";
import type { PetIdentityV1, PetSignalsV1 } from "@/lib/contracts/api";
import { PetIdentityV1Schema } from "@/lib/contracts/api";
import { PET_EVENTS, pickEvent } from "@/lib/pets/events";
import { buildIdentity, fallbackIdentity, PET_CLASS_TRAITS } from "@/lib/pets/identity";
import { localDate, mergeContext, signalEffects, stepsToday, weatherKind } from "@/lib/pets/signals";
import { neglectEffects, neglectNote, withNeglect } from "@/lib/pets/neglect";
import { applyEffects, personalizeEffects, preferenceEffects } from "@/lib/pets/stats";

const calm: PetSignalsV1 = { weather: null, stepsToday: null, headlines: [] };
const birth = new Date("2026-10-04T08:00:00Z");

function identity(overrides: Partial<PetIdentityV1> = {}): PetIdentityV1 {
  return { ...fallbackIdentity("sticker", calm, birth), ...overrides };
}

describe("pet identity", () => {
  it("derives HP and energy cost from the class, within a small jitter", () => {
    const persona = { class: "athlete" as const, personality: "Sprinter", likes: ["running"], dislikes: ["naps"], favoriteWeather: "sunny" as const };
    expect(buildIdentity(persona, calm, birth, () => 0.5)).toMatchObject({ maxHp: 125, energyMultiplier: 1.5 });
    const high = buildIdentity(persona, calm, birth, () => 1);
    const low = buildIdentity(persona, calm, birth, () => 0);
    expect(high.maxHp - PET_CLASS_TRAITS.athlete.maxHp).toBeLessThanOrEqual(8);
    expect(PET_CLASS_TRAITS.athlete.maxHp - low.maxHp).toBeLessThanOrEqual(8);
    expect(PetIdentityV1Schema.parse(high)).toEqual(high);
  });

  it("falls back to a balanced explorer that is the same for the same sticker", () => {
    const first = fallbackIdentity("abc", calm, birth);
    expect(first).toMatchObject({ class: "explorer", maxHp: 100, energyMultiplier: 1 });
    expect(fallbackIdentity("abc", calm, birth)).toEqual(first);
  });
});

describe("pet stats", () => {
  it("scales only energy costs by the multiplier and caps HP at the pet's own max", () => {
    const tired = identity({ energyMultiplier: 1.5, maxHp: 140 });
    expect(personalizeEffects({ happiness: 5, hp: 3, energy: -10 }, tired)).toEqual({ happiness: 5, hp: 3, energy: -15, gold: 0 });
    expect(personalizeEffects({ happiness: 0, hp: 0, energy: 10 }, tired)).toEqual({ happiness: 0, hp: 0, energy: 10, gold: 0 });
    expect(applyEffects({ happiness: 99, hp: 135, energy: 3 }, { happiness: 5, hp: 20, energy: -15 }, tired))
      .toEqual({ happiness: 100, hp: 140, energy: 0, gold: 20 });
  });

  it("rewards what the pet likes and penalizes what it dislikes", () => {
    const picky = identity({ likes: ["Bubbles"], dislikes: ["bath"] });
    expect(preferenceEffects("Chase bubbles after a bath", picky)).toEqual({
      effects: { happiness: -1, hp: 0, energy: 0, gold: 0 }, matched: ["+Bubbles", "-bath"],
    });
  });
});

describe("pet signals", () => {
  it("folds WMO weather codes into the pet's kinds", () => {
    expect(weatherKind(0, 5)).toBe("sunny");
    expect(weatherKind(3, 5)).toBe("cloudy");
    expect(weatherKind(3, 50)).toBe("windy");
    expect(weatherKind(61, 5)).toBe("rainy");
    expect(weatherKind(73, 5)).toBe("snowy");
    expect(weatherKind(45, 5)).toBe("foggy");
    expect(weatherKind(95, 5)).toBe("stormy");
  });

  it("rounds location and only counts steps from the phone's own today", () => {
    const now = new Date("2026-10-04T15:00:00Z");
    const context = mergeContext(null, { latitude: 37.774929, longitude: -122.419416, stepsToday: 4200, timeZone: "America/Los_Angeles" }, now)!;
    expect(context).toMatchObject({ latitude: 37.77, longitude: -122.42, stepsToday: 4200, stepsDate: "2026-10-04" });
    expect(stepsToday(context, now)).toBe(4200);
    // 08:00 UTC on the 5th is 01:00 on the 5th in Los Angeles: a new day, so yesterday's steps are gone.
    expect(localDate(new Date("2026-10-05T08:00:00Z"), "America/Los_Angeles")).toBe("2026-10-05");
    expect(stepsToday(context, new Date("2026-10-05T08:00:00Z"))).toBeNull();
    // A later context without steps keeps the steps it had.
    expect(mergeContext(context, { timeZone: "America/Los_Angeles" }, now)).toMatchObject({ stepsToday: 4200 });
  });

  it("cheers the pet in its favourite weather and after a long walk", () => {
    const walker = identity({ class: "athlete", favoriteWeather: "rainy" });
    const result = signalEffects({ weather: { kind: "rainy", temperatureC: 12, isDay: true }, stepsToday: 12_000, headlines: [] }, walker);
    // The walk itself gives energy back through the walk reward, so the big walk costs none here.
    expect(result.effects).toEqual({ happiness: 8, hp: 3, energy: 0, gold: 0 });
    expect(result.reasons).toHaveLength(2);
    expect(signalEffects(calm, walker).effects).toEqual({ happiness: 0, hp: 0, energy: 0, gold: 0 });
  });
});

describe("pet events", () => {
  const context = { identity: identity(), signals: calm, hour: 12 };

  it("never rolls special or condition-bound events it cannot have", () => {
    for (let index = 0; index < 50; index += 1) {
      const event = pickEvent(context, { special: false }, () => index / 50)!;
      expect(event.special).toBeFalsy();
      expect(event.when?.(context) ?? true).toBe(true);
    }
  });

  it("can roll weather events when the weather allows them", () => {
    const rainy = { ...context, signals: { ...calm, weather: { kind: "rainy" as const, temperatureC: 10, isDay: true } } };
    const seen = new Set<string>();
    for (let index = 0; index < 100; index += 1) seen.add(pickEvent(rainy, { special: true }, () => index / 100)!.id);
    expect(seen).toContain("puddle-party");
    expect(seen).toContain("rainy-blues");
    expect(seen).not.toContain("snow-angel");
  });

  it("has unique ids and readable details for every event", () => {
    expect(new Set(PET_EVENTS.map((event) => event.id)).size).toBe(PET_EVENTS.length);
    const rich = { identity: identity(), hour: 2, signals: { weather: { kind: "sunny" as const, temperatureC: 20, isDay: false }, stepsToday: 9000, headlines: ["Park reopens"] } };
    for (const event of PET_EVENTS) expect(event.detail(rich).length).toBeGreaterThan(0);
  });
});

describe("pet neglect", () => {
  it("leaves a recently seen pet alone and pines harder the longer its owner is away", () => {
    expect(neglectEffects(0)).toBeNull();
    expect(neglectEffects(11.9)).toBeNull();
    expect(neglectEffects(12)).toEqual({ happiness: -4, hp: -2, energy: 0, gold: 0 });
    expect(neglectEffects(30)).toEqual({ happiness: -6, hp: -3, energy: 0, gold: 0 });
    expect(neglectEffects(24 * 5)).toEqual({ happiness: -8, hp: -5, energy: 0, gold: 0 });
  });

  it("never lets a neglected visit cheer the pet up", () => {
    const neglect = neglectEffects(48)!;
    expect(withNeglect({ happiness: 10, hp: 4, energy: 6, gold: 3 }, neglect)).toEqual({ happiness: -6, hp: -3, energy: 6, gold: 3 });
    expect(withNeglect({ happiness: -5, hp: -8, energy: 0, gold: 0 }, neglect)).toEqual({ happiness: -11, hp: -11, energy: 0, gold: 0 });
    expect(withNeglect({ happiness: 10, hp: 4, energy: 6, gold: 0 }, null)).toEqual({ happiness: 10, hp: 4, energy: 6, gold: 0 });
  });

  it("says how long the owner has been gone", () => {
    expect(neglectNote(14.6)).toBe("Hasn't seen you in 14 hours.");
    expect(neglectNote(25)).toBe("Hasn't seen you in 1 day.");
    expect(neglectNote(80)).toBe("Hasn't seen you in 3 days.");
  });
});
