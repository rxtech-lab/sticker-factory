import type { PetEvolution } from "@/lib/db/schema";

/** An evolution that started longer ago than this is dead, whatever its row still says. */
export const EVOLUTION_STALE_AFTER_MS = 2 * 60 * 60 * 1000;

export const ACTIVE_EVOLUTION_STATES: PetEvolution["state"][] = ["planning", "building", "publishing"];

/** Whether the evolution says it is still running and is young enough to believe it. */
export function evolutionInFlight(evolution: PetEvolution | null | undefined, now = Date.now()): boolean {
  return !!evolution && ACTIVE_EVOLUTION_STATES.includes(evolution.state)
    && now - Date.parse(evolution.startedAt) <= EVOLUTION_STALE_AFTER_MS;
}
