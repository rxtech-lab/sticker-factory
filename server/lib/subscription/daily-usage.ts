import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import {
  DAILY_STICKER_GENERATION_ITEM,
  DAILY_STICKER_REFINEMENT_ITEM,
  fetchEntitlements,
  recordUsage,
  SubscriptionServiceError,
} from "./client";
import { subscriptionEnabled } from "./config";

/**
 * Daily allowances for the full app: one `daily_sticker_generation` per newly
 * generated sticker, one `daily_sticker_refinement` per user message.
 *
 * The limit, the reset and any overage policy live in RxSubscription; nothing
 * is counted or hard-coded here. Quick-mode requests are metered by their own
 * `quick_mode_allowance` instead and never reach this.
 */
export type DailyUsageItem = typeof DAILY_STICKER_GENERATION_ITEM | typeof DAILY_STICKER_REFINEMENT_ITEM;

const LIMIT_MESSAGES: Record<DailyUsageItem, string> = {
  [DAILY_STICKER_GENERATION_ITEM]: "You've reached today's sticker limit. Try again after it resets.",
  [DAILY_STICKER_REFINEMENT_ITEM]: "You've reached today's message limit. Try again after it resets.",
};

const allowanceSchema = z.object({
  limit: z.number().int().nonnegative().nullable(),
  remaining: z.number().int().nonnegative().nullable(),
}).refine(item => (item.limit === null) === (item.remaining === null));

function limitReached(item: DailyUsageItem) {
  return new ApiError(402, "DAILY_LIMIT_REACHED", LIMIT_MESSAGES[item], { item });
}
function notConfigured() {
  return new ApiError(503, "DAILY_USAGE_NOT_CONFIGURED", "Your daily allowance is not available yet. Please try again.");
}
function unavailable() {
  return new ApiError(503, "DAILY_USAGE_UNAVAILABLE", "Your daily allowance could not be checked. Please try again.");
}

/**
 * Usage cannot be refunded once recorded. When one request spends several
 * items, read them all first so a spent message allowance does not also cost
 * the user a sticker.
 */
async function assertAllRemaining(ownerId: string, items: DailyUsageItem[]) {
  let usage: unknown;
  try {
    ({ usage } = await fetchEntitlements(ownerId));
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw unavailable();
  }
  if (!Array.isArray(usage)) throw unavailable();
  for (const item of items) {
    const entry = usage.find(entry => typeof entry === "object" && entry !== null && "key" in entry && entry.key === item);
    if (!entry) throw notConfigured();
    const allowance = allowanceSchema.safeParse(entry);
    if (!allowance.success) throw unavailable();
    if (allowance.data.remaining === 0) throw limitReached(item);
  }
}

/** Records one use of each item against the job, or throws `402 DAILY_LIMIT_REACHED`. */
export async function consumeDailyUsage(ownerId: string, items: DailyUsageItem[], jobId: string): Promise<void> {
  if (!subscriptionEnabled()) return;
  if (items.length > 1) await assertAllRemaining(ownerId, items);
  for (const item of items) {
    try {
      const usage = await recordUsage(ownerId, item, `${item}:${jobId}`, { jobId });
      if (typeof usage.allowed !== "boolean") throw new Error("Invalid usage response");
      if (!usage.allowed) throw limitReached(item);
    } catch (error) {
      if (error instanceof ApiError) throw error;
      if (error instanceof SubscriptionServiceError && error.status === 404) throw notConfigured();
      if (error instanceof SubscriptionServiceError && error.status === 402) throw limitReached(item);
      throw unavailable();
    }
  }
}
