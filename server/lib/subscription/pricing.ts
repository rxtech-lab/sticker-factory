import type { PublishExportsRequest } from "@/lib/contracts/api";
import type { GenerationJobRow } from "@/lib/db/schema";

/** The balance unit generations are charged against, as configured in the console. */
export const CREDIT_UNIT = "credits";

/** Permission a creator needs before a pack can go live on the marketplace. */
export const PUBLISH_PERMISSION = "marketplace.publish";

type JobKind = GenerationJobRow["kind"];

/**
 * What each kind of job costs, in credits.
 *
 * Roughly proportional to what the job spends downstream. Image work dominates:
 * `animation` renders a sequence of frames and `compose` builds a whole
 * confirmed plan, so both cost more than a single generation. `chat` and `plan`
 * are text-only turns — cheap enough that charging for them would mostly
 * punish people for thinking out loud, so they are free.
 *
 * `cleanup` is deletion. Charging a user to remove their own work would be
 * indefensible, and it would let a user run out of credits with no way to free
 * storage.
 */
const JOB_COSTS: Record<JobKind, number> = {
  image: 10,
  edit: 10,
  compose: 20,
  animation: 25,
  chat: 0,
  plan: 0,
  export: 0,
  cleanup: 0,
};

export function jobCreditCost(kind: JobKind): number {
  return JOB_COSTS[kind] ?? 0;
}

/**
 * What an export costs.
 *
 * The still renditions are local `sharp` work and stay free — a user who paid
 * to generate a sticker should not pay again to get a PNG out. The animated
 * ones run a frame-by-frame encode, so they carry a price.
 */
const ANIMATED_EXPORT_COST = 5;

export function exportCreditCost(request: PublishExportsRequest): number {
  const animated = Boolean(request.apngAssetId || request.mp4AssetId);
  return animated ? ANIMATED_EXPORT_COST : 0;
}
