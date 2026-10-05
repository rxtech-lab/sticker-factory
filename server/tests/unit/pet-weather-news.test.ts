import { describe, expect, it } from "vitest";
import type { PetIdentityV1, PetSignalsV1 } from "@/lib/contracts/api";
import { fallbackIdentity } from "@/lib/pets/identity";
import { readTomorrow } from "@/lib/pets/signals";
import { forecastAdvice, forecastReminder, weatherChange } from "@/lib/pets/weather-news";

const calm: PetSignalsV1 = { weather: null, stepsToday: null, headlines: [] };
const identity = (overrides: Partial<PetIdentityV1> = {}): PetIdentityV1 =>
  ({ ...fallbackIdentity("sticker", calm, new Date("2026-10-04T08:00:00Z")), favoriteWeather: "sunny", ...overrides });

describe("pet weather news", () => {
  it("notices the weather turning bad, clearing up, and dramatic temperature swings", () => {
    const sunny = { kind: "sunny" as const, temperatureC: 22, isDay: true };
    expect(weatherChange(sunny, { ...sunny, temperatureC: 25 }, identity())).toBeNull();
    expect(weatherChange(null, sunny, identity())).toBeNull();

    const storm = weatherChange(sunny, { kind: "stormy", temperatureC: 20, isDay: true }, identity())!;
    expect(storm).toMatchObject({ id: "weather-turned", title: "The weather turned", effects: { happiness: -4 } });
    expect(storm.detail).toContain("A storm rolled in (sunny → stormy).");

    const cleared = weatherChange({ kind: "rainy", temperatureC: 15, isDay: true }, sunny, identity({ favoriteWeather: "snowy" }))!;
    expect(cleared).toMatchObject({ id: "weather-cleared", effects: { happiness: 4, energy: 2 } });

    const snap = weatherChange(sunny, { kind: "cloudy", temperatureC: 9, isDay: true }, identity())!;
    expect(snap).toMatchObject({ id: "cold-snap", title: "Sudden cold snap", effects: { hp: -2, energy: -2 } });
    expect(snap.detail).toBe("The temperature dropped from 22°C to 9°C.");

    // A rainy-loving pet is delighted when the rain comes.
    const delighted = weatherChange(sunny, { kind: "rainy", temperatureC: 20, isDay: true }, identity({ favoriteWeather: "rainy" }))!;
    expect(delighted).toMatchObject({ id: "weather-favourite", effects: { happiness: 5 } });
  });

  it("advises a coat, an umbrella, or water and a hat from tomorrow's forecast", () => {
    const now = { kind: "sunny" as const, temperatureC: 20, isDay: true };
    expect(forecastAdvice(null, now)).toBeNull();
    expect(forecastAdvice({ kind: "sunny", minC: 14, maxC: 22, precipitationChance: 5 }, now)).toBeNull();
    expect(forecastAdvice({ kind: "cloudy", minC: 4, maxC: 11, precipitationChance: 10 }, now)).toMatchObject({ bring: ["a coat"] });
    // Not cold as such, but much colder than today.
    expect(forecastAdvice({ kind: "cloudy", minC: 11, maxC: 13, precipitationChance: 10 }, { ...now, temperatureC: 24 })!.detail)
      .toContain("11° colder than now");
    expect(forecastAdvice({ kind: "rainy", minC: 6, maxC: 12, precipitationChance: 80 }, now)).toMatchObject({ bring: ["a coat", "an umbrella"] });
    expect(forecastAdvice({ kind: "cloudy", minC: 15, maxC: 20, precipitationChance: 70 }, now)!.detail)
      .toBe("Tomorrow's forecast: cloudy, 15°C–20°C (70% chance of rain). Remind your owner to bring an umbrella.");
    expect(forecastAdvice({ kind: "sunny", minC: 24, maxC: 35, precipitationChance: 0 }, now)).toMatchObject({ bring: ["water and a hat"] });
  });

  it("reads the forecast once, in the evening", () => {
    const signals: PetSignalsV1 = { ...calm, tomorrow: { kind: "rainy", minC: 5, maxC: 9, precipitationChance: 90 } };
    expect(forecastReminder({ signals, hour: 14, date: "2026-10-05", alreadyReminded: false })).toBeNull();
    expect(forecastReminder({ signals, hour: 19, date: "2026-10-05", alreadyReminded: true })).toBeNull();
    expect(forecastReminder({ signals, hour: 19, date: "2026-10-05", alreadyReminded: false }))
      .toMatchObject({ id: "forecast-reminder", debug: { reminderDate: "2026-10-05", bring: ["a coat", "an umbrella"] } });
  });

  it("reads tomorrow out of Open-Meteo's daily block", () => {
    expect(readTomorrow({
      weather_code: [0, 63], temperature_2m_max: [20, 12.34], temperature_2m_min: [10, 4.56],
      precipitation_probability_max: [0, 87.4], wind_speed_10m_max: [5, 10],
    })).toEqual({ kind: "rainy", minC: 4.6, maxC: 12.3, precipitationChance: 87 });
    expect(readTomorrow({ weather_code: [0], temperature_2m_max: [20], temperature_2m_min: [10] })).toBeNull();
    expect(readTomorrow({ weather_code: [0, 3], temperature_2m_max: [20, 18], temperature_2m_min: [10, 11], precipitation_probability_max: [0, null] }))
      .toMatchObject({ precipitationChance: null });
  });
});
