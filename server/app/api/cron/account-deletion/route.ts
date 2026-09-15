import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { sweepOverdueAccountDeletions } from "@/lib/services/account-deletion";

/**
 * Finalizes every account deletion whose grace period has run out.
 *
 * Hourly via `vercel.json`. The grace window inside the sweep is slack against clock skew with
 * rxlab-auth, which schedules the same deletion on its own timer: purging a user's stickers in the
 * minute *before* their account actually goes would delete data from an account that still exists.
 *
 * Runs on Node with no caching: this route mutates, and a cached 200 would silently stop the sweep.
 */
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const authorized = authorizeCronRequest(request);
  if (!authorized.ok) return authorized.response;

  try {
    const db = await getDatabase();
    const result = await sweepOverdueAccountDeletions(db);

    if (result.skipped.length > 0) {
      // Every entry here is a schedule that came due and did not run — cancelled mid-sweep at best,
      // a record with no fencing token at worst. Worth a log line either way.
      console.warn(`Account deletion sweep skipped ${result.skipped.length} overdue account(s)`);
    }

    return Response.json(
      { deleted: result.deleted.length, skipped: result.skipped.length },
      { headers: { "cache-control": "no-store" } },
    );
  } catch (error) {
    console.error("Account deletion sweep error:", error);
    return errorResponse(error);
  }
}
