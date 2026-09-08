// Publishing rendered exports onto a sticker, in the request that asked for it.

import { eq } from "drizzle-orm";
import type { PublishExportsRequest } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { generationJobs } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { traceEvent } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { beginJob, completeJob, failJob, type SettlementSink } from "@/lib/services/job-lifecycle";
import { bindExports } from "@/lib/services/sticker-exports";

/**
 * What the export sheet says when the server refuses a rendition.
 *
 * Only the timing codes get their own sentence, because only they describe a file the app produced
 * wrongly rather than something the person did: nothing about the sticker is broken, the build that
 * rendered it is. Everything else falls back to the server's own words, which is already more than
 * the client had.
 */
export function exportRejectionReason(error: ApiError): string {
  switch (error.code) {
    case "EXPORT_TIMING_UNVERIFIED":
    case "EXPORT_FPS_MISMATCH":
    case "EXPORT_FRAME_COUNT_MISMATCH":
    case "EXPORT_DURATION_MISMATCH":
      return "The exported animation's timing doesn't match this version of the sticker. Update the app, then publish again.";
    default:
      return error.message;
  }
}

/**
 * Runs an export job's whole lifecycle — claim, bind, complete — against the database.
 *
 * Deliberately not a workflow. A publish arrives with every rendition already drawn, uploaded and
 * verified; all that is left is `bindExports`, which is a handful of selects and one transaction
 * and touches neither storage nor a model. Handing that to the durable runtime cost four function
 * invocations — the orchestrator plus a step apiece for begin, bind and complete — each with its
 * own cold start and its own database connection, and the client sat on "Publishing to your
 * library" for all of them. This is the same reasoning that collapsed quick mode's lifecycle into
 * `quickGenerationStep`; here there is no long-running middle at all, so there is nothing left to
 * resume between and the workflow can go entirely.
 *
 * What durability bought is kept where it was actually load-bearing. The bind is idempotent by
 * construction — `publishedRevisionId` is the job id, and a second run returns the revision the
 * first one minted — so the caller retries by replaying the same idempotency key. And a failure
 * this function cannot rule a verdict on falls back to the workflow, which still has the retries.
 *
 * @param settlement where the credit charge goes. Passed `after` by the route, so the response
 *   flushes without waiting on the billing service.
 * @returns the state to report, and whether the durable runtime took the job instead.
 */
export async function publishExports(
  db: Database,
  jobId: string,
  request: PublishExportsRequest,
  options: { settlement?: SettlementSink } = {},
): Promise<{ state: "succeeded" | "failed"; retryable: boolean } | { deferToWorkflow: true }> {
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!job || job.kind !== "export") throw new Error("Export job not found");
  try {
    await beginJob(jobId);
    // The event the client's progress bar reads. It lands with the terminal one rather than ahead
    // of it now, which costs the bar a frame and is what a publish this short is worth.
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "verifying_exports", progress: 0.5 });
    const startedAt = Date.now();
    const result = await bindExports(db, job.ownerId, job.stickerId, request, job.id);
    traceEvent("publishExports:bound", { jobId, ms: Date.now() - startedAt });
    await completeJob(jobId, result, options);
    return { state: "succeeded", retryable: false };
  } catch (error) {
    // A rejected rendition is a verdict on bytes that are already uploaded: the same file fails the
    // same way on every attempt, so retrying spends the wait arriving back here. Fail once, and
    // hand the reason to the client — the sticker stays a draft either way, and "Generation failed.
    // You can retry this request." leaves someone pressing Publish forever.
    if (error instanceof ApiError && error.status < 500) {
      await failJob(db, jobId, error.message, exportRejectionReason(error), options);
      return { state: "failed", retryable: false };
    }
    // Anything else — a dropped connection, a database that is briefly unreachable — may well
    // succeed on a second attempt, and the job is already claimed and already paid for. Hand it to
    // the durable runtime, which is where this used to live and which still has the retries.
    traceEvent("publishExports:deferred", { jobId, error: error instanceof Error ? error.message.slice(0, 200) : String(error) });
    return { deferToWorkflow: true };
  }
}
