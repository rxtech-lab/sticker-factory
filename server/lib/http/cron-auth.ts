import { timingSafeEqual } from "node:crypto";

/**
 * Bearer-secret authentication for scheduled routes.
 *
 * Vercel Cron calls a plain public URL, so the only thing separating "the scheduler ran the sweep"
 * from "anyone on the internet ran the sweep" is this shared secret. Routes that finalize account
 * deletions cannot be left open, so an unset `CRON_SECRET` refuses the request rather than
 * defaulting to allow.
 */

export type CronAuthResult = { ok: true } | { ok: false; response: Response };

/** Constant-time compare, so the secret cannot be recovered a byte at a time from response timing. */
function secretMatches(provided: string, expected: string): boolean {
  const a = Buffer.from(provided, "utf8");
  const b = Buffer.from(expected, "utf8");
  // timingSafeEqual throws on a length mismatch, which would itself leak the length.
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export function authorizeCronRequest(request: Request): CronAuthResult {
  const expected = process.env.CRON_SECRET;
  if (!expected) {
    console.error("CRON_SECRET is not configured; refusing to run the scheduled job");
    return {
      ok: false,
      response: Response.json(
        { error: { code: "CRON_NOT_CONFIGURED", message: "Scheduled jobs are not configured" } },
        { status: 503, headers: { "cache-control": "no-store" } },
      ),
    };
  }

  const header = request.headers.get("authorization");
  const provided = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (!secretMatches(provided, expected)) {
    return {
      ok: false,
      response: Response.json(
        { error: { code: "UNAUTHORIZED", message: "Invalid cron credentials" } },
        { status: 401, headers: { "cache-control": "no-store" } },
      ),
    };
  }

  return { ok: true };
}
