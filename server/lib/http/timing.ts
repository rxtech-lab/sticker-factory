import { AsyncLocalStorage } from "node:async_hooks";

interface Span {
  name: string;
  ms: number;
}

interface RequestTimings {
  startedAt: number;
  spans: Span[];
}

/**
 * Per-request timing, kept in async local storage so the database layer can record its own spans
 * without every service threading a logger through its signature.
 *
 * The point is to answer "which phase burned the wall clock" from a single log line, rather than
 * bisecting a handler by hand: request totals routinely dwarf the sum of the queries, and the gap
 * is what matters (module load, JWKS fetch, JSON serialisation).
 */
const store = new AsyncLocalStorage<RequestTimings>();

export function runTimed<T>(fn: () => Promise<T>): Promise<T> {
  return store.run({ startedAt: performance.now(), spans: [] }, fn);
}

export function recordSpan(name: string, ms: number): void {
  store.getStore()?.spans.push({ name, ms });
}

/** Times `fn`, recording it as `name`, whether it resolves or throws. */
export async function timeStage<T>(name: string, fn: () => Promise<T>): Promise<T> {
  const startedAt = performance.now();
  try {
    return await fn();
  } finally {
    recordSpan(name, performance.now() - startedAt);
  }
}

function round(ms: number): number {
  return Math.round(ms * 10) / 10;
}

/**
 * Collapses repeated spans (one per query, say) into `name xN=totalms` so a page that issues many
 * small statements stays readable.
 */
function aggregate(spans: Span[]): Array<{ name: string; ms: number; count: number }> {
  const totals = new Map<string, { name: string; ms: number; count: number }>();
  for (const span of spans) {
    const existing = totals.get(span.name);
    if (existing) {
      existing.ms += span.ms;
      existing.count += 1;
    } else {
      totals.set(span.name, { name: span.name, ms: span.ms, count: 1 });
    }
  }
  return [...totals.values()];
}

export function elapsedMs(): number {
  const timings = store.getStore();
  return timings ? performance.now() - timings.startedAt : 0;
}

/** `auth=812.4ms user=203.1ms handler=241.7ms db x2=430.2ms` */
export function formatTimings(): string {
  const timings = store.getStore();
  if (!timings) return "";
  return aggregate(timings.spans)
    .map(({ name, ms, count }) => `${name}${count > 1 ? ` x${count}` : ""}=${round(ms)}ms`)
    .join(" ");
}

/** The same spans as a `Server-Timing` header, so clients and devtools can read the breakdown. */
export function serverTimingHeader(): string | undefined {
  const timings = store.getStore();
  if (!timings) return undefined;
  const parts = aggregate(timings.spans).map(({ name, ms, count }) =>
    `${name.replace(/[^a-zA-Z0-9_-]/g, "_")};dur=${round(ms)}${count > 1 ? `;desc="x${count}"` : ""}`);
  parts.push(`total;dur=${round(performance.now() - timings.startedAt)}`);
  return parts.join(", ");
}
