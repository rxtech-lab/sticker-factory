import type { PetIdentityV1, PetSignalsV1 } from "@/lib/contracts/api";
import type { PetForecast } from "./signals";
import { ZERO_EFFECTS, type PetEffects } from "./stats";

type Weather = NonNullable<PetSignalsV1["weather"]>;

/** Something the weather did that the pet tells its owner about on a visit, instead of a random event. */
export type PetWeatherNews = {
  id: string;
  title: string;
  detail: string;
  effects: PetEffects;
  debug: Record<string, unknown>;
};

/** Weather that keeps a pet indoors. */
const BAD_WEATHER = new Set<Weather["kind"]>(["rainy", "stormy", "snowy"]);
/** A swing this big between two readings is dramatic enough to remark on. */
export const TEMPERATURE_SWING_C = 8;
/** Tomorrow is coat weather when it gets this cold, or this much colder than now. */
export const COAT_BELOW_C = 10;
export const COAT_DROP_C = 6;
/** Rain this likely is worth an umbrella. */
export const UMBRELLA_CHANCE = 60;
/** Tomorrow is hot enough to warn about water and shade. */
export const HOT_ABOVE_C = 32;
/** The local hour from which the pet reads tomorrow's forecast to its owner: the evening before. */
export const FORECAST_REMINDER_HOUR = 18;

const degrees = (celsius: number) => `${Math.round(celsius)}°C`;

/**
 * How the weather moved since the pet last felt it, or null when nothing changed enough to say.
 * Turning bad or clearing up counts; so does a temperature swing of `TEMPERATURE_SWING_C` or more.
 * A pet whose favourite weather just arrived is pleased whatever it is.
 */
export function weatherChange(before: Weather | null | undefined, after: Weather | null | undefined, identity: PetIdentityV1 | null): PetWeatherNews | null {
  if (!before || !after) return null;
  const swing = Math.round((after.temperatureC - before.temperatureC) * 10) / 10;
  const turnedBad = !BAD_WEATHER.has(before.kind) && BAD_WEATHER.has(after.kind);
  const clearedUp = BAD_WEATHER.has(before.kind) && !BAD_WEATHER.has(after.kind);
  const bigSwing = Math.abs(swing) >= TEMPERATURE_SWING_C;
  if (!turnedBad && !clearedUp && !bigSwing) return null;

  const favourite = identity?.favoriteWeather === after.kind && before.kind !== after.kind;
  const sky = turnedBad ? (after.kind === "stormy" ? "A storm rolled in" : after.kind === "snowy" ? "It started snowing" : "It started raining")
    : clearedUp ? "The sky cleared up" : null;
  const temperature = bigSwing
    ? `${swing < 0 ? "dropped" : "jumped"} from ${degrees(before.temperatureC)} to ${degrees(after.temperatureC)}`
    : null;
  const title = favourite ? "Its favourite weather arrived"
    : turnedBad ? "The weather turned"
      : clearedUp ? "The sky cleared"
        : swing < 0 ? "Sudden cold snap" : "Sudden heat";
  const detail = [
    sky ? `${sky} (${before.kind} → ${after.kind}).` : "",
    temperature ? `The temperature ${temperature}.` : "",
  ].filter(Boolean).join(" ");

  let effects = { ...ZERO_EFFECTS };
  if (favourite) effects = { ...effects, happiness: 5 };
  else if (turnedBad) effects = { ...effects, happiness: -4 };
  else if (clearedUp) effects = { ...effects, happiness: 4, energy: 2 };
  if (bigSwing) effects = { ...effects, hp: effects.hp - 2, energy: effects.energy - 2 };

  return {
    id: favourite ? "weather-favourite" : turnedBad ? "weather-turned" : clearedUp ? "weather-cleared" : swing < 0 ? "cold-snap" : "heat-spike",
    title,
    detail,
    effects,
    debug: { before, after, swing, turnedBad, clearedUp, favourite },
  };
}

/**
 * What the owner should bring tomorrow, by the forecast: a coat when it is cold or much colder than
 * now, an umbrella when rain is likely, water and a hat in the heat. Null when tomorrow needs nothing.
 */
export function forecastAdvice(tomorrow: PetForecast | null | undefined, now: Weather | null | undefined): { bring: string[]; detail: string } | null {
  if (!tomorrow) return null;
  const bring: string[] = [];
  const reasons: string[] = [];
  const colder = now ? Math.round(now.temperatureC - tomorrow.maxC) : 0;
  if (tomorrow.kind === "snowy") {
    bring.push("a warm coat");
    reasons.push("snow");
  } else if (tomorrow.minC <= COAT_BELOW_C || colder >= COAT_DROP_C) {
    bring.push("a coat");
    reasons.push(colder >= COAT_DROP_C ? `${colder}° colder than now` : `as low as ${degrees(tomorrow.minC)}`);
  }
  if (tomorrow.kind === "rainy" || tomorrow.kind === "stormy" || (tomorrow.precipitationChance ?? 0) >= UMBRELLA_CHANCE) {
    bring.push("an umbrella");
    reasons.push(tomorrow.kind === "stormy" ? "storms"
      : tomorrow.precipitationChance !== null ? `${tomorrow.precipitationChance}% chance of rain` : "rain");
  }
  if (tomorrow.maxC >= HOT_ABOVE_C) {
    bring.push("water and a hat");
    reasons.push(`up to ${degrees(tomorrow.maxC)}`);
  }
  if (!bring.length) return null;
  return {
    bring,
    detail: `Tomorrow's forecast: ${tomorrow.kind}, ${degrees(tomorrow.minC)}–${degrees(tomorrow.maxC)} (${reasons.join(", ")}). `
      + `Remind your owner to bring ${bring.join(" and ")}.`,
  };
}

/**
 * The evening reminder about tomorrow, once per local day: only from `FORECAST_REMINDER_HOUR`, and
 * only when the forecast calls for something. `alreadyReminded` is whether today's was given.
 */
export function forecastReminder(input: {
  signals: PetSignalsV1;
  hour: number;
  date: string;
  alreadyReminded: boolean;
}): PetWeatherNews | null {
  if (input.alreadyReminded || input.hour < FORECAST_REMINDER_HOUR) return null;
  const advice = forecastAdvice(input.signals.tomorrow, input.signals.weather);
  if (!advice) return null;
  return {
    id: "forecast-reminder",
    title: "Checked tomorrow's forecast",
    detail: advice.detail,
    // Looking out for its owner is its own small pleasure.
    effects: { ...ZERO_EFFECTS, happiness: 1 },
    debug: { reminderDate: input.date, bring: advice.bring, tomorrow: input.signals.tomorrow },
  };
}
