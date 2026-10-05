/**
 * One-line traces for the pet's life, the companion to `traceEvent`'s `[gen]` lines.
 *
 * Every line carries the user id and, where there is one, the life id, so a single pet can be
 * followed with `grep '[pet]' | grep <userId>`: what it read, what it rolled, what moved its stats,
 * and where a life workflow stopped. The durable record a user can see is `pet_events`; these are
 * for whoever is reading the function logs.
 */
export function petLog(event: string, fields: Record<string, unknown> = {}): void {
  console.log(`[pet] ${event}`, fields);
}

/** The process-wide random source, swappable so a test can decide which event fires. */
let random: () => number = Math.random;

export function petRandom(): number {
  return random();
}

export function setPetRandomForTests(source: (() => number) | undefined): void {
  random = source ?? Math.random;
}
