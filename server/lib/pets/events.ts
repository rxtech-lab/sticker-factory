import type { PetIdentityV1, PetSignalsV1 } from "@/lib/contracts/api";
import type { PetClass } from "./identity";
import type { PetEffects } from "./stats";

/** What an event can see when deciding whether it may happen. */
export type PetEventContext = {
  identity: PetIdentityV1 | null;
  signals: PetSignalsV1;
  /** The owner's local hour, 0–23. */
  hour: number;
};

export type PetEventDefinition = {
  id: string;
  title: string;
  detail: (context: PetEventContext) => string;
  effects: PetEffects;
  weight: number;
  /** Only the life workflow's visits roll these; a sticker send never does. */
  special?: boolean;
  /** These classes are three times as likely to have it happen to them. */
  classes?: PetClass[];
  when?: (context: PetEventContext) => boolean;
};

const isNight = ({ hour, signals }: PetEventContext) => signals.weather ? !signals.weather.isDay : hour >= 21 || hour < 5;
const weatherIs = (...kinds: string[]) => ({ signals }: PetEventContext) => !!signals.weather && kinds.includes(signals.weather.kind);
const stepsAtLeast = (steps: number) => ({ signals }: PetEventContext) => signals.stepsToday !== null && signals.stepsToday >= steps;

/**
 * Small things that happen to a pet. Effects are before personalization: an energy cost here is
 * scaled by the pet's own multiplier when it lands.
 */
export const PET_EVENTS: PetEventDefinition[] = [
  { id: "found-trinket", title: "Found a shiny trinket", weight: 3, effects: { happiness: 6, hp: 0, energy: -2, gold: 8 },
    classes: ["explorer", "trickster"], detail: () => "Something sparkly turned up under the sofa." },
  { id: "snack-stash", title: "Discovered a snack stash", weight: 3, effects: { happiness: 4, hp: 5, energy: 3 },
    detail: () => "A forgotten stash of snacks — a feast!" },
  { id: "tummy-ache", title: "Tummy ache", weight: 1, effects: { happiness: -3, hp: -8, energy: -2 },
    detail: () => "Maybe that last snack was a bad idea." },
  { id: "new-friend", title: "Made a new friend", weight: 2, effects: { happiness: 7, hp: 0, energy: -3 },
    classes: ["trickster", "explorer"], detail: () => "A neighbourhood critter stopped by to play." },
  { id: "zoomies", title: "Got the zoomies", weight: 3, effects: { happiness: 5, hp: 2, energy: -8 }, when: stepsAtLeast(8_000),
    classes: ["athlete", "explorer"], detail: ({ signals }) => `All ${signals.stepsToday} of today's steps went straight to its legs.` },
  { id: "couch-day", title: "Lazy couch day", weight: 3, effects: { happiness: -2, hp: 0, energy: 8 },
    when: ({ signals }) => signals.stepsToday !== null && signals.stepsToday < 2_000, classes: ["dreamer"],
    detail: () => "Barely a step taken today, so it curled up on the couch." },
  { id: "caught-drizzle", title: "Caught in the drizzle", weight: 3, effects: { happiness: -4, hp: -5, energy: -2 },
    when: (context) => weatherIs("rainy")(context) && context.identity?.favoriteWeather !== "rainy",
    detail: () => "Got soaked on the way home and is a little sniffly." },
  { id: "puddle-party", title: "Puddle party", weight: 3, effects: { happiness: 8, hp: 0, energy: -4 }, when: weatherIs("rainy"),
    classes: ["trickster", "explorer"], detail: () => "Splashed in every puddle it could find." },
  { id: "sunbeam-nap", title: "Sunbeam nap", weight: 3, effects: { happiness: 4, hp: 3, energy: 6 },
    when: (context) => weatherIs("sunny")(context) && !isNight(context), classes: ["dreamer", "guardian"],
    detail: ({ signals }) => `Napped in a warm sunbeam (${signals.weather?.temperatureC}°C).` },
  { id: "snow-angel", title: "Made a snow angel", weight: 3, effects: { happiness: 7, hp: -2, energy: -5 }, when: weatherIs("snowy"),
    detail: () => "Flopped into fresh snow and flapped its arms." },
  { id: "storm-jitters", title: "Storm jitters", weight: 3, effects: { happiness: -6, hp: 0, energy: -3 }, when: weatherIs("stormy"),
    detail: () => "Thunder rattled the windows; it is hiding under a blanket." },
  { id: "kite-day", title: "Chased the wind", weight: 2, effects: { happiness: 5, hp: 0, energy: -6 }, when: weatherIs("windy"),
    classes: ["athlete", "trickster"], detail: () => "Ran after leaves the wind was carrying." },
  { id: "foggy-mystery", title: "Lost in the fog", weight: 2, effects: { happiness: -2, hp: 0, energy: -3 }, when: weatherIs("foggy"),
    classes: ["scholar"], detail: () => "Wandered into the fog and solved a very small mystery." },
  { id: "stargazing", title: "Stargazing", weight: 2, effects: { happiness: 5, hp: 0, energy: 2 },
    when: (context) => isNight(context) && !weatherIs("rainy", "stormy", "foggy", "cloudy")(context), classes: ["scholar", "dreamer"],
    detail: () => "Counted stars until it lost count." },
  { id: "bad-dream", title: "Bad dream", weight: 1, effects: { happiness: -5, hp: 0, energy: -3 },
    when: ({ hour }) => hour < 5, detail: () => "Woke up from a dream about losing its favourite toy." },
  { id: "read-the-news", title: "Read the news", weight: 2, effects: { happiness: 2, hp: 0, energy: -2 },
    when: ({ signals }) => signals.headlines.length > 0, classes: ["scholar"],
    detail: ({ signals }) => `Read about: ${signals.headlines[0]}` },

  // Special: only the life workflow's periodic visits roll these.
  { id: "festival", title: "Festival day", weight: 2, special: true, effects: { happiness: 10, hp: 0, energy: -10 },
    detail: () => "A parade went by and it danced the whole way." },
  { id: "growth-spurt", title: "Growth spurt", weight: 1, special: true, effects: { happiness: 3, hp: 10, energy: -5 },
    classes: ["guardian", "athlete"], detail: () => "It feels bigger and stronger today." },
  { id: "perfect-weather", title: "Perfect weather", weight: 4, special: true, effects: { happiness: 8, hp: 2, energy: 2 },
    when: ({ identity, signals }) => !!identity && signals.weather?.kind === identity.favoriteWeather,
    detail: ({ signals }) => `Its favourite weather today: ${signals.weather?.kind}.` },
  { id: "long-walk-reward", title: "Long walk reward", weight: 4, special: true, effects: { happiness: 6, hp: 4, energy: -4, gold: 10 },
    when: stepsAtLeast(6_000), classes: ["athlete", "explorer"],
    detail: ({ signals }) => `You walked ${signals.stepsToday} steps today and it walked every one with you.` },
  { id: "headline-reaction", title: "Big news", weight: 3, special: true, effects: { happiness: 0, hp: 0, energy: -2 },
    when: ({ signals }) => signals.headlines.length > 0, classes: ["scholar"],
    detail: ({ signals }) => `Heard the news: ${signals.headlines[0]}` },
  { id: "rainy-blues", title: "Rainy-day blues", weight: 2, special: true, effects: { happiness: -6, hp: -2, energy: 0 },
    when: (context) => weatherIs("rainy", "stormy")(context) && context.identity?.favoriteWeather !== context.signals.weather?.kind,
    detail: () => "Stuck indoors all day, staring at the rain." },
];

/**
 * Picks one event that may happen now, weighted, or null. `special` includes the workflow-only
 * events. `random` is called exactly once, so a test can choose the outcome.
 */
export function pickEvent(context: PetEventContext, options: { special: boolean }, random: () => number): PetEventDefinition | null {
  const candidates = PET_EVENTS
    .filter((event) => (options.special || !event.special) && (event.when?.(context) ?? true))
    .map((event) => ({
      event,
      weight: event.weight * (context.identity && event.classes?.includes(context.identity.class) ? 3 : 1),
    }));
  const total = candidates.reduce((sum, candidate) => sum + candidate.weight, 0);
  if (total === 0) return null;
  let roll = random() * total;
  for (const candidate of candidates) {
    roll -= candidate.weight;
    if (roll < 0) return candidate.event;
  }
  return candidates[candidates.length - 1].event;
}

/** The chance a sticker send also rolls a random event. */
export const SEND_EVENT_CHANCE = 0.3;
