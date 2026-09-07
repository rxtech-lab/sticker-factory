import type { PublishExportsRequest } from "@/lib/contracts/api";
import { planVideoCount, type PlanV1 } from "@/lib/contracts/plan";
import type { GenerationJobRow } from "@/lib/db/schema";

/** The RxSubscription balance unit API spend is charged against. */
export const CREDIT_UNIT = "points";

/** Permission required to publish a pack to the marketplace. */
export const PUBLISH_PERMISSION = "marketplace.publish";

type JobKind = GenerationJobRow["kind"];

/**
 * The estimated point hold placed before each kind of job starts.
 *
 * This is not the charge. The charge comes from Vercel AI Gateway's exact USD
 * cost after each text or image request, converted at 70 points/USD. A hold
 * keeps concurrent jobs from spending the same balance and any unused amount
 * is released when the job closes.
 *
 * `cleanup` is deletion. Charging a user to remove their own work would be
 * indefensible, and it would let a user run out of points with no way to free
 * storage.
 */
const JOB_HOLDS: Record<JobKind, number> = {
  image: 10,
  edit: 10,
  compose: 20,
  animation: 25,
  chat: 10,
  plan: 10,
  export: 0,
  cleanup: 0,
};

export function jobCreditHold(kind: JobKind): number {
  return JOB_HOLDS[kind] ?? 0;
}

/**
 * What a video layer adds to a compose hold.
 *
 * A 480p clip of the longest allowed length is about 4 points at list price, and the still it is
 * animated from is an ordinary generation the base hold already assumes. Ten covers the clip, a
 * retry, and a pricier model without holding back a meaningful slice of anyone's balance.
 */
const VIDEO_LAYER_HOLD = 10;

/** The compose hold for a specific plan: the flat estimate, plus one video's worth per clip. */
export function composeCreditHold(plan: Pick<PlanV1, "layers">): number {
  return jobCreditHold("compose") + VIDEO_LAYER_HOLD * planVideoCount(plan);
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

/**
 * The same price, quoted before the renditions exist.
 *
 * A quick publish (`lib/services/quick-publish.ts`) renders on the server, so the hold has to be
 * placed from the document's kind rather than from a request describing files that have not been
 * drawn yet. It charges the same as the app's publish deliberately: where the encode runs is not
 * something the user chose, and billing the same work differently by surface would be arbitrary.
 */
export function quickPublishCreditCost(kind: "static" | "animated"): number {
  return kind === "animated" ? ANIMATED_EXPORT_COST : 0;
}
