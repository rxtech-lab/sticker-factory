import { getAiProvider } from "@/lib/ai/gateway";
import type { PetContextV1, PetIdentityV1, PetSignalsV1 } from "@/lib/contracts/api";
import type { PetStoredContext } from "@/lib/db/schema";
import { describeError } from "@/lib/observability/trace";
import type { PetWeatherKind } from "./identity";
import { petLog } from "./log";
import { ZERO_EFFECTS, type PetEffects } from "./stats";

/** How long a search for headlines is reused before the pet looks again. */
export const HEADLINES_TTL_MS = 3 * 60 * 60 * 1000;
/** Context older than this says nothing about now: yesterday's location, last week's steps. */
const CONTEXT_STALE_MS = 24 * 60 * 60 * 1000;

export const EMPTY_SIGNALS: PetSignalsV1 = { weather: null, stepsToday: null, headlines: [], tomorrow: null };

/** The phone's local date in `timeZone`, falling back to UTC for a zone this runtime cannot read. */
export function localDate(at: Date, timeZone: string | undefined): string {
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone: timeZone ?? "UTC", year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
  } catch {
    return at.toISOString().slice(0, 10);
  }
}

/** The hour of day in `timeZone`, 0–23. */
export function localHour(at: Date, timeZone: string | undefined): number {
  try {
    return Number(new Intl.DateTimeFormat("en-GB", { timeZone: timeZone ?? "UTC", hour: "2-digit", hourCycle: "h23" }).format(at));
  } catch {
    return at.getUTCHours();
  }
}

/**
 * Folds what the phone just said into what it said before. Location is rounded to two decimals —
 * about a kilometre — before it is stored: weather needs no more than that, and the server should
 * not hold more than it needs. Steps are stamped with the local date they were counted on.
 */
export function mergeContext(stored: PetStoredContext | null, incoming: PetContextV1 | undefined, now: Date): PetStoredContext | null {
  if (!incoming) return stored;
  const round = (value: number) => Math.round(value * 100) / 100;
  const timeZone = incoming.timeZone ?? stored?.timeZone;
  return {
    ...stored,
    ...(incoming.latitude !== undefined && incoming.longitude !== undefined
      ? { latitude: round(incoming.latitude), longitude: round(incoming.longitude) } : {}),
    ...(incoming.stepsToday !== undefined ? { stepsToday: incoming.stepsToday, stepsDate: localDate(now, timeZone) } : {}),
    ...(timeZone ? { timeZone } : {}),
    updatedAt: now.toISOString(),
  };
}

/** Steps counted today, in the phone's own time zone, or null when the count is from another day. */
export function stepsToday(context: PetStoredContext | null, now: Date): number | null {
  if (context?.stepsToday === undefined || !context.stepsDate) return null;
  return context.stepsDate === localDate(now, context.timeZone) ? context.stepsToday : null;
}

type WeatherFetcher = (latitude: number, longitude: number) => Promise<PetSignalsV1["weather"]>;
type ForecastFetcher = (latitude: number, longitude: number) => Promise<PetForecast | null>;
export type PetForecast = NonNullable<PetSignalsV1["tomorrow"]>;
let weatherFetcherForTests: WeatherFetcher | undefined;
let forecastFetcherForTests: ForecastFetcher | undefined;

export function setWeatherFetcherForTests(fetcher: WeatherFetcher | undefined): void {
  weatherFetcherForTests = fetcher;
}

export function setForecastFetcherForTests(fetcher: ForecastFetcher | undefined): void {
  forecastFetcherForTests = fetcher;
}

/** WMO weather interpretation codes, as Open-Meteo reports them, folded into the pet's few kinds. */
export function weatherKind(code: number, windKmh: number): PetWeatherKind {
  if (code >= 95) return "stormy";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "snowy";
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) return "rainy";
  if (code === 45 || code === 48) return "foggy";
  if (windKmh >= 40) return "windy";
  return code <= 1 ? "sunny" : "cloudy";
}

type OpenMeteoBody = {
  current?: { temperature_2m?: number; weather_code?: number; wind_speed_10m?: number; is_day?: number };
  daily?: {
    weather_code?: number[];
    temperature_2m_max?: number[];
    temperature_2m_min?: number[];
    precipitation_probability_max?: (number | null)[];
    wind_speed_10m_max?: number[];
  };
};

const tenths = (value: number) => Math.round(value * 10) / 10;

/**
 * The current weather and tomorrow's forecast at a rounded location, from Open-Meteo (no key, no
 * account), in one request. Days are counted in `timeZone` — the owner's tomorrow, not the
 * server's. Either half is null when it cannot be read in five seconds: a pet that does not know
 * the weather just does not mention it. Tests and mock-services runs never reach the network.
 */
export async function fetchWeather(
  latitude: number,
  longitude: number,
  timeZone?: string,
): Promise<{ weather: PetSignalsV1["weather"]; tomorrow: PetForecast | null }> {
  if (weatherFetcherForTests || forecastFetcherForTests) {
    return {
      weather: await weatherFetcherForTests?.(latitude, longitude) ?? null,
      tomorrow: await forecastFetcherForTests?.(latitude, longitude) ?? null,
    };
  }
  if (process.env.NODE_ENV === "test" || process.env.STICKER_FACTORY_MOCK_SERVICES === "true") return { weather: null, tomorrow: null };
  try {
    const url = new URL("https://api.open-meteo.com/v1/forecast");
    url.searchParams.set("latitude", String(latitude));
    url.searchParams.set("longitude", String(longitude));
    url.searchParams.set("current", "temperature_2m,weather_code,wind_speed_10m,is_day");
    url.searchParams.set("daily", "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max");
    url.searchParams.set("forecast_days", "2");
    url.searchParams.set("timezone", timeZone ?? "auto");
    const response = await fetch(url, { signal: AbortSignal.timeout(5_000) });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = await response.json() as OpenMeteoBody;
    const current = body.current;
    const weather = current?.weather_code === undefined || current.temperature_2m === undefined ? null : {
      kind: weatherKind(current.weather_code, current.wind_speed_10m ?? 0),
      temperatureC: tenths(current.temperature_2m),
      isDay: current.is_day !== 0,
    };
    return { weather, tomorrow: readTomorrow(body.daily) };
  } catch (error) {
    petLog("signals.weather:failed", { error: describeError(error) });
    return { weather: null, tomorrow: null };
  }
}

/** The second day of Open-Meteo's daily block — tomorrow — or null when any part of it is missing. */
export function readTomorrow(daily: OpenMeteoBody["daily"]): PetForecast | null {
  const code = daily?.weather_code?.[1];
  const max = daily?.temperature_2m_max?.[1];
  const min = daily?.temperature_2m_min?.[1];
  if (typeof code !== "number" || typeof max !== "number" || typeof min !== "number") return null;
  const chance = daily?.precipitation_probability_max?.[1];
  return {
    kind: weatherKind(code, daily?.wind_speed_10m_max?.[1] ?? 0),
    minC: tenths(min),
    maxC: tenths(max),
    precipitationChance: typeof chance === "number" ? Math.max(0, Math.min(100, Math.round(chance))) : null,
  };
}

/**
 * Everything the pet can know about its owner's world right now.
 *
 * Headlines are the expensive part — a web search — so they are reused for `HEADLINES_TTL_MS`
 * unless `refreshHeadlines` says otherwise; a failed search keeps the last ones rather than none.
 */
export async function resolveSignals(input: {
  context: PetStoredContext | null;
  previous: PetSignalsV1 | null;
  previousAt: Date | null;
  identity: PetIdentityV1 | null;
  now: Date;
  refreshHeadlines?: boolean;
  userId: string;
}): Promise<{ signals: PetSignalsV1; headlinesRefreshed: boolean }> {
  const { context, now } = input;
  const fresh = context && now.getTime() - new Date(context.updatedAt).getTime() < CONTEXT_STALE_MS ? context : null;
  const headlinesFresh = !input.refreshHeadlines && input.previousAt
    && now.getTime() - input.previousAt.getTime() < HEADLINES_TTL_MS;
  const [outlook, headlines] = await Promise.all([
    fresh?.latitude !== undefined && fresh.longitude !== undefined ? fetchWeather(fresh.latitude, fresh.longitude, fresh.timeZone) : null,
    headlinesFresh ? null : searchHeadlines(input.userId, fresh, input.identity, now),
  ]);
  const weather = outlook?.weather ?? null;
  const signals: PetSignalsV1 = {
    weather,
    stepsToday: stepsToday(context, now),
    headlines: headlines ?? input.previous?.headlines ?? [],
    tomorrow: outlook?.tomorrow ?? null,
  };
  petLog("signals:resolved", {
    userId: input.userId,
    weather: weather?.kind ?? null,
    temperatureC: weather?.temperatureC ?? null,
    tomorrow: signals.tomorrow?.kind ?? null,
    stepsToday: signals.stepsToday,
    headlines: signals.headlines.length,
    headlinesRefreshed: headlines !== null,
  });
  return { signals, headlinesRefreshed: headlines !== null };
}

async function searchHeadlines(userId: string, context: PetStoredContext | null, identity: PetIdentityV1 | null, now: Date): Promise<string[] | null> {
  try {
    const headlines = await getAiProvider().searchPetHeadlines({
      timeZone: context?.timeZone ?? null,
      latitude: context?.latitude ?? null,
      longitude: context?.longitude ?? null,
      interests: identity?.likes ?? [],
      date: localDate(now, context?.timeZone),
    });
    return headlines.map((headline) => headline.trim().slice(0, 160)).filter(Boolean).slice(0, 3);
  } catch (error) {
    petLog("signals.headlines:failed", { userId, error: describeError(error) });
    return null;
  }
}

/**
 * How the world moves the pet before anything happens to it: its favourite weather cheers it, a
 * storm unsettles it, a long walk is good for it — more so for the classes that love walking.
 */
export function signalEffects(signals: PetSignalsV1, identity: PetIdentityV1 | null): { effects: PetEffects; reasons: string[] } {
  const reasons: string[] = [];
  let effects = { ...ZERO_EFFECTS };
  const add = (delta: Partial<PetEffects>, reason: string) => {
    effects = {
      happiness: effects.happiness + (delta.happiness ?? 0),
      hp: effects.hp + (delta.hp ?? 0),
      energy: effects.energy + (delta.energy ?? 0),
      gold: effects.gold,
    };
    reasons.push(reason);
  };
  const walker = identity?.class === "athlete" || identity?.class === "explorer";
  if (signals.weather && identity && signals.weather.kind === identity.favoriteWeather) {
    add({ happiness: 4 }, `favourite weather (${signals.weather.kind})`);
  } else if (signals.weather?.kind === "stormy" && identity?.class !== "trickster") {
    add({ happiness: -3 }, "storm outside");
  }
  if (signals.weather && (signals.weather.temperatureC >= 33 || signals.weather.temperatureC <= -5)) {
    add({ hp: -2, energy: -2 }, `harsh temperature (${signals.weather.temperatureC}°C)`);
  }
  if (signals.stepsToday !== null) {
    if (signals.stepsToday >= 10_000) add({ happiness: walker ? 4 : 2, hp: 3 }, `big walk (${signals.stepsToday} steps)`);
    else if (signals.stepsToday < 1_500) add({ happiness: walker ? -4 : -1, energy: 2 }, `barely walked (${signals.stepsToday} steps)`);
  }
  return { effects, reasons };
}
