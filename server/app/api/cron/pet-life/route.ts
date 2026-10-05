import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { revivePetLives } from "@/lib/services/pet-life-runner";

/**
 * Restarts the life workflow of every pet whose run retired or stalled. Hourly via `vercel.json`.
 *
 * Mutates and starts runs, so never cached.
 */
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const authorized = authorizeCronRequest(request);
  if (!authorized.ok) return authorized.response;
  try {
    const result = await revivePetLives(await getDatabase());
    return Response.json(result, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    console.error("[pet] life revival error:", error);
    return errorResponse(error);
  }
}
