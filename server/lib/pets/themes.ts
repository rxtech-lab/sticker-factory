import { PET_LIMITED_THEME_CATEGORIES, type PetSignalsV1, type PetThemeCategory } from "@/lib/contracts/api";
import type { PetStoredContext, PetThemeRules, PetThemeUsage } from "@/lib/db/schema";
import { currentLocation, distanceKm } from "./home";
import type { PetWeatherKind } from "./identity";
import { localDate } from "./signals";

/** The most a place may change one stat by on each of the pet's visits there. */
export const THEME_EFFECT_MAX = 5;
export const THEME_EFFECT_MIN = -4;
/** How often the pet's agent looks for new everyday places, and how many it may find at once. */
export const THEME_DISCOVERY_INTERVAL_MS = 24 * 60 * 60 * 1000;
export const THEME_DISCOVERY_MAX = 2;
/** Everyday places past this many stop being looked for; trips, events and accidents still come. */
export const THEME_REVISITABLE_MAX = 16;
/** A daily allowance shorter than this is not worth going for; longer than this is no limit at all. */
export const THEME_DAILY_MINUTES_MIN = 30;
export const THEME_DAILY_MINUTES_MAX = 12 * 60;

/** How long each kind of limited place lasts, in hours, and how near the owner must be to go. */
const LIMITED_HOURS: Record<"travel" | "event" | "accident", { min: number; max: number }> = {
  travel: { min: 24, max: 7 * 24 },
  event: { min: 6, max: 72 },
  accident: { min: 6, max: 48 },
};
const PLACE_RADIUS_KM = { travel: 60, nearby: 3 };

export type ThemeEffects = { happiness: number; hp: number; energy: number };

export function isLimitedTheme(category: PetThemeCategory): category is (typeof PET_LIMITED_THEME_CATEGORIES)[number] {
  return (PET_LIMITED_THEME_CATEGORIES as readonly string[]).includes(category);
}

const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, Math.round(value)));

/** Minutes since local midnight in `timeZone`. */
export function localMinutesOfDay(at: Date, timeZone: string | undefined): number {
  try {
    const [hour, minute] = new Intl.DateTimeFormat("en-GB", { timeZone: timeZone ?? "UTC", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
      .format(at).split(":").map(Number);
    return hour * 60 + minute;
  } catch {
    return at.getUTCHours() * 60 + at.getUTCMinutes();
  }
}

/** Whether `hour` falls in `hours`, `to` exclusive; a window like 22–6 runs through midnight. */
export function withinHours(hours: { from: number; to: number }, hour: number): boolean {
  return hours.from < hours.to ? hour >= hours.from && hour < hours.to : hour >= hours.from || hour < hours.to;
}

/**
 * Counts the time the pet spent where it is since the last count, onto the owner's local date. A new
 * day starts from nothing, counting only the part of the gap that fell after midnight.
 */
export function accrueThemeUsage(
  usage: PetThemeUsage | null,
  themeId: string | null,
  now: Date,
  timeZone: string | undefined,
): PetThemeUsage {
  const date = localDate(now, timeZone);
  if (!usage) return { date, accruedAt: now.toISOString(), minutes: {} };
  let elapsed = Math.max(0, (now.getTime() - new Date(usage.accruedAt).getTime()) / 60_000);
  const minutes = usage.date === date ? { ...usage.minutes } : {};
  if (usage.date !== date) elapsed = Math.min(elapsed, localMinutesOfDay(now, timeZone));
  if (themeId) minutes[themeId] = (minutes[themeId] ?? 0) + Math.round(elapsed);
  return { date, accruedAt: now.toISOString(), minutes };
}

/** Minutes left today at a place that limits them, or null for one that does not. */
export function minutesLeftToday(
  theme: { id: string; rulesJson: PetThemeRules },
  usage: PetThemeUsage | null,
  now: Date,
  timeZone: string | undefined,
): number | null {
  if (theme.rulesJson.dailyMinutes === null) return null;
  const spent = usage?.date === localDate(now, timeZone) ? usage.minutes[theme.id] ?? 0 : 0;
  return Math.max(0, theme.rulesJson.dailyMinutes - spent);
}

const pad = (hour: number) => `${String(hour % 24).padStart(2, "0")}:00`;

/**
 * Whether the pet can be at this place right now, and if not, why, in a sentence for its owner.
 * Every rule must hold: not expired, time left today, open at this hour, the right weather, and
 * the owner near enough when the place is somewhere in particular.
 */
export function themeAvailability(
  theme: { id: string; state: "available" | "expired"; expiresAt: Date | null; rulesJson: PetThemeRules },
  world: { context: PetStoredContext | null; signals: PetSignalsV1 | null; usage: PetThemeUsage | null; now: Date },
): { available: true } | { available: false; reason: string } {
  const { rulesJson: rules } = theme;
  const { context, now } = world;
  if (theme.state === "expired" || (theme.expiresAt && theme.expiresAt <= now)) {
    return { available: false, reason: "This was a one-time place, and it has passed." };
  }
  if (minutesLeftToday(theme, world.usage, now, context?.timeZone) === 0) {
    return { available: false, reason: `Your pet has had today's ${rules.dailyMinutes} minutes here. Back tomorrow.` };
  }
  if (rules.hours && !withinHours(rules.hours, Math.floor(localMinutesOfDay(now, context?.timeZone) / 60))) {
    return { available: false, reason: `Open ${pad(rules.hours.from)}–${pad(rules.hours.to)} your time.` };
  }
  if (rules.weather?.length) {
    const kind = world.signals?.weather?.kind;
    if (!kind || !rules.weather.includes(kind)) {
      return { available: false, reason: `Only when it is ${rules.weather.join(" or ")} where you are.` };
    }
  }
  if (rules.place) {
    const here = currentLocation(context, now);
    if (!here) return { available: false, reason: `Only near ${rules.place.label}. Your pet does not know where you are.` };
    if (distanceKm(here, rules.place) > rules.place.radiusKm) {
      return { available: false, reason: `Only while you are near ${rules.place.label}.` };
    }
  }
  return { available: true };
}

/** A place as the agent designed it, before the server holds it to the rules. */
export type DesignedTheme = {
  title: string;
  description: string;
  scene: string;
  category: PetThemeCategory;
  effects: ThemeEffects;
  dailyMinutes: number | null;
  hours: { from: number; to: number } | null;
  weather: PetWeatherKind[] | null;
  /** Whether the place is where the owner is now, and only there: a name for it, or null. */
  placeLabel: string | null;
  /** How long a limited place lasts; ignored for the others. */
  lastsHours: number | null;
};

/**
 * Holds a designed place to the rules: each stat within bounds and good for something, a daily
 * allowance worth having, a real opening window, a place pinned where the owner is (a trip always
 * is), and a limited place's end within what its kind allows. Null when it names a place but the
 * owner's location is unknown — it could never be gone to.
 */
export function sanitizeTheme(
  theme: DesignedTheme,
  world: { location: { latitude: number; longitude: number } | null; now: Date },
): { title: string; description: string; scene: string; category: PetThemeCategory; effects: ThemeEffects;
  rules: PetThemeRules; expiresAt: Date | null } | null {
  const effects = {
    happiness: clamp(theme.effects.happiness, THEME_EFFECT_MIN, THEME_EFFECT_MAX),
    hp: clamp(theme.effects.hp, THEME_EFFECT_MIN, THEME_EFFECT_MAX),
    energy: clamp(theme.effects.energy, THEME_EFFECT_MIN, THEME_EFFECT_MAX),
  };
  if (effects.happiness <= 0 && effects.hp <= 0 && effects.energy <= 0) effects.happiness = 1;
  const travel = theme.category === "travel";
  const label = theme.placeLabel?.trim().slice(0, 40) || (travel ? "this trip" : null);
  if (label && !world.location) return null;
  const place = label && world.location
    ? { label, ...world.location, radiusKm: travel ? PLACE_RADIUS_KM.travel : PLACE_RADIUS_KM.nearby } : null;
  const minutes = theme.dailyMinutes === null ? null : clamp(theme.dailyMinutes, THEME_DAILY_MINUTES_MIN, THEME_DAILY_MINUTES_MAX + 1);
  const hours = theme.hours && theme.hours.from % 24 !== theme.hours.to % 24
    ? { from: clamp(theme.hours.from, 0, 23), to: clamp(theme.hours.to, 0, 24) } : null;
  const weather = theme.weather?.length ? [...new Set(theme.weather)] : null;
  let expiresAt: Date | null = null;
  if (isLimitedTheme(theme.category)) {
    const { min, max } = LIMITED_HOURS[theme.category];
    expiresAt = new Date(world.now.getTime() + clamp(theme.lastsHours ?? min, min, max) * 3_600_000);
  }
  return {
    title: theme.title.trim().slice(0, 32),
    description: theme.description.trim().slice(0, 160),
    scene: theme.scene,
    category: theme.category,
    effects,
    rules: { dailyMinutes: minutes && minutes <= THEME_DAILY_MINUTES_MAX ? minutes : null, hours, weather, place },
    expiresAt,
  };
}

/** "+2 happiness, −1 energy" for a diary line. */
export function describeThemeEffects(effects: ThemeEffects): string {
  return (["happiness", "hp", "energy"] as const)
    .filter((stat) => effects[stat] !== 0)
    .map((stat) => `${effects[stat] > 0 ? "+" : "−"}${Math.abs(effects[stat])} ${stat === "hp" ? "HP" : stat}`)
    .join(", ");
}
