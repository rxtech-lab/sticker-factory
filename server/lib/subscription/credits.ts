import { eq, sql } from "drizzle-orm";
import { totalApiCostPoints, type AiApiCostEvent } from "@/lib/ai/cost";
import type { Database } from "@/lib/db/client";
import { generationJobs, type GenerationJobRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  InsufficientCreditsError,
  fetchEntitlements,
  releaseReservation,
  reserveCredits,
  settleReservation,
  SubscriptionServiceError,
} from "./client";
import { subscriptionEnabled } from "./config";
import { CREDIT_UNIT, PUBLISH_PERMISSION } from "./pricing";

/**
 * Credits are *held* before a job is queued and only *charged* when it
 * succeeds.
 *
 * Generation is asynchronous and fallible — a provider times out, a workflow
 * dies, a user hits stop — and charging up front would mean billing people for
 * stickers they never received. A reservation makes the balance unavailable
 * immediately, so a user cannot queue ten jobs on credits for one, and returns
 * it whole on any ending that is not success.
 *
 * The hold is keyed to the job row, so the settle or release always finds it
 * again no matter which of the several terminal paths the job takes.
 */

/** A hold long enough for the slowest turn, short enough that a lost job frees itself. */
const RESERVATION_TTL_SECONDS = 3_600;

/**
 * Places a hold for a job that is about to be created.
 *
 * Returns the reservation id to store on the job row, or null when there is
 * nothing to hold — billing is unconfigured, or the job is free.
 *
 * @throws ApiError 402 when the user cannot afford it.
 */
export async function holdCreditsForJob(input: {
  ownerId: string;
  amount: number;
  idempotencyKey: string;
  description: string;
  metadata?: Record<string, unknown>;
}): Promise<string | null> {
  if (!subscriptionEnabled() || input.amount <= 0) return null;

  try {
    const reservation = await reserveCredits({
      rxlabUserId: input.ownerId,
      unit: CREDIT_UNIT,
      amount: input.amount,
      idempotencyKey: input.idempotencyKey,
      description: input.description,
      metadata: input.metadata,
      expiresInSeconds: RESERVATION_TTL_SECONDS,
    });
    return reservation.reservationId;
  } catch (error) {
    if (error instanceof InsufficientCreditsError) {
      throw new ApiError(
        402,
        "INSUFFICIENT_CREDITS",
        "You do not have enough points for this. Top up or upgrade your plan to keep creating.",
        { required: error.required, available: error.available, unit: CREDIT_UNIT },
      );
    }
    if (error instanceof SubscriptionServiceError) {
      throw new ApiError(error.status >= 500 ? 503 : error.status, "SUBSCRIPTION_UNAVAILABLE", error.message);
    }
    throw error;
  }
}

/**
 * Settles a successful job at its exact API-priced point total and releases
 * the unused part of the estimate. Exports keep their fixed non-AI charge.
 *
 * Failures here are logged and swallowed. The job really did succeed and the
 * user really does have their sticker; refusing to acknowledge that because
 * the billing service hiccuped would be the worse outcome. The hold expires on
 * its own, so the credits come back rather than being stranded.
 */
export async function chargeJobCredits(db: Database, job: GenerationJobRow): Promise<void> {
  if (!job.reservationId || job.reservationAmount <= 0) return;
  const amount = job.kind === "export"
    ? job.reservationAmount
    : totalApiCostPoints({
      textCostNanodollars: job.apiTextCostNanodollars,
      imagePoints: job.apiImagePoints,
      videoPoints: job.apiVideoPoints,
    });
  try {
    const settlement = await settleReservation({
      reservationId: job.reservationId,
      amount,
      idempotencyKey: `settle:${job.id}`,
      description: `Sticker ${job.kind}`,
      metadata: job.kind === "export"
        ? { jobId: job.id, kind: job.kind }
        : {
          jobId: job.id,
          kind: job.kind,
          textCostNanodollars: job.apiTextCostNanodollars,
          imageCostNanodollars: job.apiImageCostNanodollars,
          imagePoints: job.apiImagePoints,
          videoCostNanodollars: job.apiVideoCostNanodollars,
          videoPoints: job.apiVideoPoints,
          chargedPoints: amount,
        },
    });
    if (settlement.operationShortfallAmount > 0) {
      console.error("A generation job's API-priced point charge was only partially settled", {
        jobId: job.id,
        reservationId: job.reservationId,
        requested: settlement.operationRequestedAmount,
        settled: settlement.operationSettledAmount,
        shortfall: settlement.operationShortfallAmount,
      });
    }
    await clearJobReservation(db, job.id);
  } catch (error) {
    console.error("Could not settle a generation job's credit hold", {
      jobId: job.id,
      reservationId: job.reservationId,
      error,
    });
  }
}

/**
 * Persists one Gateway-priced call as soon as its response arrives.
 *
 * Workflow steps may be replayed. Recording before the next side effect makes
 * each provider call that actually happened part of the final turn total,
 * including a paid call whose surrounding step later has to retry.
 */
export async function recordJobApiCost(
  db: Database,
  jobId: string,
  event: AiApiCostEvent,
): Promise<void> {
  if (event.kind === "text") {
    if (event.costNanodollars <= 0) return;
    await db.update(generationJobs).set({
      apiTextCostNanodollars: sql`${generationJobs.apiTextCostNanodollars} + ${event.costNanodollars}`,
    }).where(eq(generationJobs.id, jobId));
    return;
  }

  if (event.costNanodollars <= 0 && event.points <= 0) return;
  if (event.kind === "video") {
    await db.update(generationJobs).set({
      apiVideoCostNanodollars: sql`${generationJobs.apiVideoCostNanodollars} + ${event.costNanodollars}`,
      apiVideoPoints: sql`${generationJobs.apiVideoPoints} + ${event.points}`,
    }).where(eq(generationJobs.id, jobId));
    return;
  }
  await db.update(generationJobs).set({
    apiImageCostNanodollars: sql`${generationJobs.apiImageCostNanodollars} + ${event.costNanodollars}`,
    apiImagePoints: sql`${generationJobs.apiImagePoints} + ${event.points}`,
  }).where(eq(generationJobs.id, jobId));
}

/**
 * Returns a hold whose job never made it into the database.
 *
 * The hold has to be placed before the insert, because its id is one of the
 * inserted values — so a row that loses the one-active-job-per-sticker race
 * leaves a hold behind with nothing to settle it.
 */
export async function abandonHold(
  reservationId: string | null,
  jobId: string,
  reason: string,
): Promise<void> {
  if (!reservationId) return;
  try {
    await releaseReservation({
      reservationId,
      idempotencyKey: `release:${jobId}`,
      reason,
    });
  } catch (error) {
    console.error("Could not release the credit hold of a job that was never created", {
      jobId,
      reservationId,
      reason,
      error,
    });
  }
}

/**
 * Returns a job's hold, on any ending that is not success.
 *
 * Swallows failures for the same reason as {@link chargeJobCredits}: an
 * unreleased hold expires by itself, so the user is made whole either way, and
 * a billing outage must not stop a job from being marked failed.
 */
export async function refundJobCredits(
  db: Database,
  job: GenerationJobRow,
  reason: string,
): Promise<void> {
  if (!job.reservationId) return;
  await abandonHold(job.reservationId, job.id, reason);
  await clearJobReservation(db, job.id);
}

/**
 * Drops the reference once the hold is closed, so a later replay of the same
 * terminal transition cannot try to settle an already-settled reservation.
 */
async function clearJobReservation(db: Database, jobId: string): Promise<void> {
  await db.update(generationJobs)
    .set({ reservationId: null, reservationAmount: 0 })
    .where(eq(generationJobs.id, jobId));
}

/**
 * Closes out a job's hold according to how it ended.
 *
 * The single call site for every terminal transition, so a new ending cannot
 * quietly forget to settle.
 */
export async function finalizeJobCredits(
  db: Database,
  job: GenerationJobRow,
  outcome: "succeeded" | "failed" | "cancelled",
): Promise<void> {
  if (outcome === "succeeded") {
    await chargeJobCredits(db, job);
    return;
  }
  await refundJobCredits(db, job, outcome === "cancelled" ? "user_cancelled" : "generation_failed");
}

/**
 * Refuses an action the user's plan does not include.
 *
 * Unlike generation, publishing a pack costs us nothing to run — it is a tier
 * feature rather than a metered one — so it checks a permission instead of
 * spending credits.
 */
export async function requirePermission(
  ownerId: string,
  permission: string,
  message: string,
): Promise<void> {
  if (!subscriptionEnabled()) return;

  let permissions: string[];
  try {
    ({ permissions } = await fetchEntitlements(ownerId));
  } catch (error) {
    if (error instanceof SubscriptionServiceError) {
      // Fail closed. An entitlement check that cannot run is not a pass, and
      // publishing is rare enough that asking the user to try again shortly is
      // a fair trade for not giving away a paid tier during an outage.
      throw new ApiError(503, "SUBSCRIPTION_UNAVAILABLE", error.message);
    }
    throw error;
  }

  if (!permissions.includes(permission)) {
    throw new ApiError(402, "SUBSCRIPTION_REQUIRED", message, { permission });
  }
}

/** Refuses a publish when the creator's plan does not include the marketplace. */
export async function requirePublishEntitlement(ownerId: string): Promise<void> {
  await requirePermission(
    ownerId,
    PUBLISH_PERMISSION,
    "Publishing packs to the marketplace needs a paid plan.",
  );
}
