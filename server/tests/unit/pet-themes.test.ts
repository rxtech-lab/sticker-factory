import { describe, expect, it } from "vitest";
import type { PetStoredContext, PetThemeRules } from "@/lib/db/schema";
import { HOME_MOVES_AFTER_MS, isTraveling, TRAVEL_DISTANCE_KM, distanceKm } from "@/lib/pets/home";
import { mergeContext } from "@/lib/pets/signals";
import { accrueThemeUsage, minutesLeftToday, sanitizeTheme, THEME_EFFECT_MAX, themeAvailability, withinHours, type DesignedTheme } from "@/lib/pets/themes";

const sanFrancisco = { latitude: 37.77, longitude: -122.42 };
const oakland = { latitude: 37.8, longitude: -122.27 };
const tokyo = { latitude: 35.68, longitude: 139.69 };
const noRules: PetThemeRules = { dailyMinutes: null, hours: null, weather: null, place: null };

function at(iso: string) {
  return new Date(iso);
}

describe("pet home and travel", () => {
  it("learns home from the first location, starts a trip far from it, and ends it back home", () => {
    const start = at("2026-10-01T12:00:00Z");
    let context = mergeContext(null, { ...sanFrancisco, timeZone: "UTC" }, start)!;
    expect(context.home).toEqual(sanFrancisco);
    expect(isTraveling(context, start)).toBe(false);

    // Across the bay is a day out, not a trip.
    context = mergeContext(context, oakland, at("2026-10-01T15:00:00Z"))!;
    expect(distanceKm(oakland, sanFrancisco)).toBeLessThan(TRAVEL_DISTANCE_KM);
    expect(context.awaySince).toBeUndefined();

    const landed = at("2026-10-02T09:00:00Z");
    context = mergeContext(context, tokyo, landed)!;
    expect(isTraveling(context, landed)).toBe(true);
    expect(context.awaySince).toBe(landed.toISOString());
    expect(context.home).toEqual(sanFrancisco);

    const back = at("2026-10-09T09:00:00Z");
    context = mergeContext(context, sanFrancisco, back)!;
    expect(isTraveling(context, back)).toBe(false);
    expect(context.awaySince).toBeUndefined();
  });

  it("moves home once the owner has been somewhere else for weeks", () => {
    const start = at("2026-10-01T12:00:00Z");
    let context = mergeContext(null, sanFrancisco, start)!;
    context = mergeContext(context, tokyo, start)!;
    const later = new Date(start.getTime() + HOME_MOVES_AFTER_MS);
    context = mergeContext(context, tokyo, later)!;
    expect(context.home).toEqual(tokyo);
    expect(isTraveling(context, later)).toBe(false);
  });

  it("forgets every location, home included, when tracking is turned off", () => {
    const now = at("2026-10-01T12:00:00Z");
    const tracked = mergeContext(null, { ...sanFrancisco, stepsToday: 4_000, timeZone: "UTC" }, now)!;
    const off = mergeContext(tracked, { trackLocation: false, timeZone: "UTC" }, now)!;
    expect(off).not.toHaveProperty("latitude");
    expect(off).not.toHaveProperty("home");
    expect(off.stepsToday).toBe(4_000);
    expect(isTraveling(off, now)).toBe(false);
  });
});

describe("pet theme rules", () => {
  const context: PetStoredContext = { ...sanFrancisco, timeZone: "UTC", home: sanFrancisco, updatedAt: "2026-10-01T11:00:00Z" };
  const theme = (rules: Partial<PetThemeRules>, extra: { expiresAt?: Date; state?: "available" | "expired" } = {}) => ({
    id: "cafe", state: extra.state ?? "available" as const, expiresAt: extra.expiresAt ?? null, rulesJson: { ...noRules, ...rules },
  });
  const world = (now: Date, extra: Partial<Parameters<typeof themeAvailability>[1]> = {}) =>
    ({ context, signals: null, usage: null, now, ...extra });

  it("opens only within its hours, which may run through midnight", () => {
    expect(withinHours({ from: 18, to: 24 }, 23)).toBe(true);
    expect(withinHours({ from: 22, to: 6 }, 3)).toBe(true);
    expect(withinHours({ from: 22, to: 6 }, 12)).toBe(false);
    const nightMarket = theme({ hours: { from: 18, to: 24 } });
    expect(themeAvailability(nightMarket, world(at("2026-10-01T19:00:00Z"))).available).toBe(true);
    expect(themeAvailability(nightMarket, world(at("2026-10-01T12:00:00Z")))).toEqual({ available: false, reason: "Open 18:00–00:00 your time." });
  });

  it("allows only its weather and only near its place", () => {
    const snowHill = theme({ weather: ["snowy"] });
    const now = at("2026-10-01T12:00:00Z");
    expect(themeAvailability(snowHill, world(now, { signals: { weather: { kind: "rainy", temperatureC: 3, isDay: true }, stepsToday: null, headlines: [] } })).available).toBe(false);
    expect(themeAvailability(snowHill, world(now, { signals: { weather: { kind: "snowy", temperatureC: -1, isDay: true }, stepsToday: null, headlines: [] } })).available).toBe(true);

    const pier = theme({ place: { label: "the Embarcadero", ...sanFrancisco, radiusKm: 3 } });
    expect(themeAvailability(pier, world(now)).available).toBe(true);
    expect(themeAvailability(pier, world(now, { context: { ...context, ...tokyo } }))).toEqual({ available: false, reason: "Only while you are near the Embarcadero." });
    // Tracking off, or a location from days ago: the place cannot be known.
    expect(themeAvailability(pier, world(now, { context: { timeZone: "UTC", updatedAt: now.toISOString() } })).available).toBe(false);
    expect(themeAvailability(pier, world(at("2026-10-04T12:00:00Z"))).available).toBe(false);
  });

  it("counts each day's minutes and closes once they are used up", () => {
    const morning = at("2026-10-01T09:00:00Z");
    let usage = accrueThemeUsage(null, "cafe", morning, "UTC");
    expect(usage.minutes).toEqual({});
    usage = accrueThemeUsage(usage, "cafe", at("2026-10-01T10:00:00Z"), "UTC");
    usage = accrueThemeUsage(usage, "cafe", at("2026-10-01T10:30:00Z"), "UTC");
    expect(usage.minutes.cafe).toBe(90);
    const cafe = theme({ dailyMinutes: 90 });
    expect(minutesLeftToday(cafe, usage, at("2026-10-01T10:30:00Z"), "UTC")).toBe(0);
    expect(themeAvailability(cafe, world(at("2026-10-01T10:30:00Z"), { usage })).available).toBe(false);

    // A new day starts from nothing, counting only the time after midnight.
    const tomorrow = accrueThemeUsage(usage, "cafe", at("2026-10-02T00:20:00Z"), "UTC");
    expect(tomorrow).toMatchObject({ date: "2026-10-02", minutes: { cafe: 20 } });
    expect(minutesLeftToday(cafe, tomorrow, at("2026-10-02T00:20:00Z"), "UTC")).toBe(70);
  });

  it("never lets an expired place be gone to again", () => {
    const now = at("2026-10-01T12:00:00Z");
    expect(themeAvailability(theme({}, { state: "expired" }), world(now)).available).toBe(false);
    expect(themeAvailability(theme({}, { expiresAt: now }), world(now)).available).toBe(false);
    expect(themeAvailability(theme({}, { expiresAt: new Date(now.getTime() + 1) }), world(now)).available).toBe(true);
  });

  it("holds what the agent designs to the rules", () => {
    const now = at("2026-10-01T12:00:00Z");
    const designed: DesignedTheme = {
      title: "  Shibuya Crossing  ", description: "Lights", scene: "A busy crossing", category: "travel",
      effects: { happiness: 40, hp: -40, energy: 0 }, dailyMinutes: 5, hours: { from: 9, to: 9 }, weather: ["rainy", "rainy"],
      placeLabel: null, placeRadiusKm: null, lastsHours: 1_000,
    };
    const trip = sanitizeTheme(designed, { location: tokyo, now })!;
    expect(trip.title).toBe("Shibuya Crossing");
    expect(trip.effects).toEqual({ happiness: THEME_EFFECT_MAX, hp: -4, energy: 0 });
    expect(trip.rules).toMatchObject({ dailyMinutes: 30, hours: null, weather: ["rainy"], place: { label: "this trip", ...tokyo, radiusKm: 60 } });
    expect(trip.expiresAt).toEqual(new Date(now.getTime() + 7 * 24 * 3_600_000));
    // A trip, or any place pinned somewhere, cannot be made without knowing where the owner is.
    expect(sanitizeTheme(designed, { location: null, now })).toBeNull();

    const park = { ...designed, category: "nature" as const, effects: { happiness: 0, hp: 0, energy: -2 }, dailyMinutes: null };
    // A place named for a city reaches across it: pinned in Central, open from Sha Tin, not from Macau.
    const central = { latitude: 22.25, longitude: 114.15 };
    const harbour = sanitizeTheme({ ...park, weather: null, placeLabel: "Hong Kong" }, { location: central, now })!;
    const near = (spot: { latitude: number; longitude: number }) => themeAvailability({ id: "harbour", state: "available", expiresAt: null,
      rulesJson: harbour.rules }, world(now, { context: { ...context, ...spot } })).available;
    expect(near({ latitude: 22.38, longitude: 114.19 })).toBe(true);
    expect(near({ latitude: 22.14, longitude: 113.56 })).toBe(false);
    // The agent sizes a place to what it names: one park reaches only so far, never under the
    // kilometre the location is known to, and never as far as a trip.
    const pond = sanitizeTheme({ ...park, weather: null, placeLabel: "Victoria Park", placeRadiusKm: 3 }, { location: central, now })!;
    expect(pond.rules.place).toEqual({ label: "Victoria Park", ...central, radiusKm: 3 });
    expect(sanitizeTheme({ ...park, placeLabel: "Victoria Park", placeRadiusKm: 0 }, { location: central, now })!.rules.place?.radiusKm).toBe(2);
    expect(sanitizeTheme({ ...park, placeLabel: "Hong Kong", placeRadiusKm: 500 }, { location: central, now })!.rules.place?.radiusKm).toBe(60);
    expect(sanitizeTheme({ ...park, placeLabel: "Golden Gate Park" }, { location: null, now })).toBeNull();
    // An everyday place anywhere needs no location, never expires, and is always good for something.
    expect(sanitizeTheme(park, { location: null, now })).toMatchObject({
      effects: { happiness: 1, hp: 0, energy: -2 }, rules: { dailyMinutes: null, place: null }, expiresAt: null,
    });
  });
});
