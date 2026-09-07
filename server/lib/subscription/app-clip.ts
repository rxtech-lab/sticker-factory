import { finalizeJobCredits } from "./credits";
import { z } from "zod";
import { and, eq, inArray, isNotNull } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { type Database } from "@/lib/db/client";
import { generationJobs } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { fetchEntitlements, QUICK_MODE_USAGE_ITEM, recordGenerationUsage, SubscriptionServiceError } from "./client";

export function isAppClipClient(principal: Pick<ApiPrincipal, "clientId">): boolean {
  const clientID = process.env.APP_CLIP_OAUTH_CLIENT_ID?.trim();
  return Boolean(clientID && principal.clientId === clientID);
}

/** A Clip token cannot escape into richer generation or marketplace writes. */
export function assertAppClipRoute(request: Request, principal: ApiPrincipal) {
  if (!isAppClipClient(principal)) return;
  const path = new URL(request.url).pathname;
  const read = request.method === "GET" && (
    path === "/api/v1/app-clip/allowance" ||
    /^\/api\/v1\/stickers\/[^/]+$/.test(path) ||
    /^\/api\/v1\/jobs\/[^/]+(?:\/events)?$/.test(path) ||
    /^\/api\/v1\/assets\/[^/]+\/(download|preview)$/.test(path));
  const write = request.method === "POST" && (
    path === "/api/v1/stickers" || path === "/api/v1/uploads" ||
    /^\/api\/v1\/uploads\/[^/]+\/complete$/.test(path) ||
    /^\/api\/v1\/stickers\/[^/]+\/chat\/messages$/.test(path));
  if (!read && !write) throw new ApiError(403, "APP_CLIP_OPERATION_NOT_ALLOWED", "Open the full app for this action.");
}

export async function recordAppClipUsage(ownerId: string, jobId: string): Promise<void> {
  try {
    const usage = await recordGenerationUsage(ownerId, jobId);
    if (typeof usage.allowed !== "boolean") throw new Error("Invalid usage response");
    if (!usage.allowed) throw new ApiError(402, "APP_CLIP_LIMIT_REACHED", "You have used your generation allowance. Try again after it resets.");
  } catch (error) {
    if (error instanceof SubscriptionServiceError && error.status === 404) {
      throw new ApiError(503, "APP_CLIP_USAGE_NOT_CONFIGURED", "Your generation allowance is not available yet. Please try again.");
    }
    if (error instanceof SubscriptionServiceError && error.status === 402) {
      throw new ApiError(402, "APP_CLIP_LIMIT_REACHED", "You have used your generation allowance. Try again after it resets.");
    }
    if (error instanceof ApiError && error.status === 402) throw error;
    throw new ApiError(503, "APP_CLIP_USAGE_UNAVAILABLE", "Your generation allowance could not be checked. Please try again.");
  }
}

export async function appClipAllowance(db: Database, ownerId: string) {
  const unsettled = await db.select().from(generationJobs).where(and(
    eq(generationJobs.ownerId, ownerId),
    eq(generationJobs.appClip, true), isNotNull(generationJobs.reservationId),
    inArray(generationJobs.state, ["succeeded", "failed", "cancelled"]),
  )).limit(100);
  for (const job of unsettled) await finalizeJobCredits(db, job, job.state === "succeeded" ? "succeeded" : "failed");
  return quickGenerationPolicy(ownerId);
}


const policySchema = z.object({
  plans: z.array(z.object({ planKey: z.string().min(1) })),
  usage: z.array(z.unknown()),
});
const allowanceSchema = z.object({
  key: z.literal(QUICK_MODE_USAGE_ITEM),
  used: z.number().int().nonnegative(),
  limit: z.number().int().nonnegative().nullable(),
  remaining: z.number().int().nonnegative().nullable(),
  resetsAt: z.string().nullable(),
}).refine(item => (item.limit === null) === (item.remaining === null) &&
  (item.limit === null || (item.remaining !== null && item.remaining <= item.limit)));

/** The same backend response supplies the plan and its resolved per-user allowance. */
export async function quickGenerationPolicy(ownerId: string) {
  const parsed = policySchema.safeParse(await fetchEntitlements(ownerId));
  if (!parsed.success) {
    throw new ApiError(503, "APP_CLIP_USAGE_UNAVAILABLE", "Your generation allowance could not be checked. Please try again.");
  }
  const item = parsed.data.usage.find(item => typeof item === "object" && item !== null &&
    "key" in item && item.key === QUICK_MODE_USAGE_ITEM);
  if (!item) throw new ApiError(503, "APP_CLIP_USAGE_NOT_CONFIGURED", "Quick generation is not available yet.");
  const allowance = allowanceSchema.safeParse(item);
  if (!allowance.success) {
    throw new ApiError(503, "APP_CLIP_USAGE_UNAVAILABLE", "Your generation allowance could not be checked. Please try again.");
  }
  // RxSubscription auto-enrolls the `free` plan. A paid plan can coexist with
  // it in another plan group, so any non-free plan must still pay points.
  const chargesPoints = parsed.data.plans.some(plan => plan.planKey !== "free");
  return { ...allowance.data, chargesPoints };
}
