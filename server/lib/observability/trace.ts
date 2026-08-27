/**
 * Timed, prefixed logging for the generation path.
 *
 * A turn stuck on "Running…" is the failure this exists for. The job row only moves when a step
 * returns or throws, so when the step's process is killed — a platform timeout, an OOM, a dev-server
 * restart — the row keeps the last state it was given and nothing anywhere says how far the turn
 * got. These lines are that record: every one carries the job id, so a single turn can be followed
 * end to end with `grep '[gen]' | grep <jobId>`, and the last line printed is where it died.
 */
export function traceEvent(
  event: string,
  fields: Record<string, unknown> = {},
): void {
  console.log(`[gen] ${event}`, fields);
}

/**
 * Describes an error in one line, following the `cause` chain.
 *
 * The AI SDK wraps a provider's `TimeoutError` in its own error, so the name that says what actually
 * happened is usually two or three levels down — the same reason `isAbortError` walks the chain.
 */
export function describeError(error: unknown): string {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; current && depth < 5; depth += 1) {
    parts.push(
      current instanceof Error
        ? `${current.name}: ${current.message}`
        : String(current),
    );
    current = (current as { cause?: unknown }).cause;
  }
  return parts.join(" <- ").slice(0, 500);
}

/**
 * Runs `work`, logging when it starts, how long it took, and whether it threw.
 *
 * The start line matters as much as the end one: a span that logged its start and never its end is
 * exactly the shape of a call that was still in flight when the process went away.
 */
export async function traceSpan<T>(
  event: string,
  fields: Record<string, unknown>,
  work: () => Promise<T>,
): Promise<T> {
  const startedAt = Date.now();
  traceEvent(`${event}:start`, fields);
  try {
    const value = await work();
    traceEvent(`${event}:ok`, { ...fields, ms: Date.now() - startedAt });
    return value;
  } catch (error) {
    traceEvent(`${event}:fail`, {
      ...fields,
      ms: Date.now() - startedAt,
      error: describeError(error),
    });
    throw error;
  }
}
