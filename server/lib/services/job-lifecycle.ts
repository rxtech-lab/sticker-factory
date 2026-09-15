// A generation job's three transitions — claimed, finished, failed — and the settlement that
// follows each of them.
//
// These live here rather than beside the workflow that usually drives them because they are not
// workflow-shaped. A publish runs its whole lifecycle inside the request that asked for it (see
// `publishExports` in `sticker-exports.ts`), and it needs the same transitions, the same events and
// the same credit settlement as a turn that spends minutes in the durable runtime. The `"use step"`
// wrappers in `workflows/sticker-generation/steps.ts` are thin shells over these.

import { pushLiveActivityUpdate } from "@/lib/notifications/live-activities";
import { and, eq } from "drizzle-orm";
import { firstRow, getDatabase, type Database } from "@/lib/db/client";
import { chatMessages, generationEvents, generationJobs, stickers, type GenerationJobRow } from "@/lib/db/schema";
import { isNotifiableJobKind, notifyGenerationFinished, type GenerationOutcome } from "@/lib/notifications/generation";
import { traceEvent } from "@/lib/observability/trace";
import { chargeJobCredits, refundJobCredits } from "@/lib/subscription/credits";

/**
 * Where a terminal transition's settlement goes — charging or releasing the credit hold, and the
 * push that says the turn is over.
 *
 * A workflow step awaits it, which is the default: the invocation ends the moment the step returns,
 * so a promise left dangling there is a charge that never happens. A request handler hands this
 * `after` from `next/server` instead, because the settlement talks to the billing service over the
 * network and the client is waiting on the response — see the exports route.
 */
export type SettlementSink = (work: () => Promise<void>) => void;

async function settle(sink: SettlementSink | undefined, work: () => Promise<void>): Promise<void> {
  if (sink) sink(work); else await work();
}

export async function beginJob(jobId: string): Promise<void> {
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  traceEvent("beginJobStep", { jobId, kind: job?.kind, state: job?.state, attempts: job?.attempts });
  if (!job) throw new Error("Generation job not found");
  // A step the runtime is re-running: the first attempt already claimed the job and then died
  // without reaching a terminal state, which is what a turn stuck on "Running…" looks like here.
  if (job.state === "running") {
    traceEvent("beginJobStep:reentered", { jobId, attempts: job.attempts });
    return;
  }
  if (job.state !== "queued") throw new Error(`Job cannot start from state ${job.state}`);
  await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({ state: "running", attempts: job.attempts + 1, updatedAt: now })
      .where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "queued"))).returning({ id: generationJobs.id });
    if (changed.length === 0) throw new Error("Job was cancelled before it started");
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "started",
      dataJson: { attempt: job.attempts + 1 },
      createdAt: now,
    });
  });
  await pushLiveActivityUpdate(db, job.ownerId, jobId);
}

/**
 * Sends the "this turn is over" banner, from the side that watched the turn.
 *
 * Called only after the terminal transition has actually committed, so a step that re-runs over an
 * already-finished job cannot announce it twice. `notifyGenerationFinished` swallows its own
 * failures, so awaiting it is free of risk.
 */
async function announceJobEnded(
  db: Database,
  job: GenerationJobRow,
  outcome: GenerationOutcome,
): Promise<void> {
  if (!isNotifiableJobKind(job.kind)) return;
  const sticker = await db.select({ id: stickers.id, title: stickers.title, status: stickers.status })
    .from(stickers).where(and(eq(stickers.id, job.stickerId), eq(stickers.ownerId, job.ownerId))).then(firstRow);
  // A sticker the user has since deleted has nothing to open.
  if (!sticker || sticker.status === "deleting") return;
  await notifyGenerationFinished(db, {
    ownerId: job.ownerId,
    jobId: job.id,
    stickerId: sticker.id,
    // Read after `summarizeStickerTitleStep`, so the banner uses the name the library will show
    // rather than the first sentence the user happened to type.
    stickerTitle: sticker.title,
    outcome,
  });
}

export async function completeJob(
  jobId: string,
  result: Record<string, unknown>,
  options: { settlement?: SettlementSink } = {},
): Promise<void> {
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  traceEvent("completeJobStep", { jobId, state: job?.state });
  if (!job) return;
  if (job.state === "succeeded") return;
  await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({ state: "succeeded", updatedAt: now, completedAt: now })
      .where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "running"))).returning({ id: generationJobs.id });
    if (changed.length === 0) throw new Error("Job is no longer running");
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "complete" }).where(and(
        eq(chatMessages.id, job.sourceMessageId),
        eq(chatMessages.jobId, job.id),
      ));
    }
    await tx.insert(generationEvents).values({ jobId, ownerId: job.ownerId, type: "completed", dataJson: result, createdAt: now });
  });
  await pushLiveActivityUpdate(db, job.ownerId, jobId);
  await settle(options.settlement, async () => {
    // The one path that actually charges. Everything else returns the hold.
    await chargeJobCredits(db, job);
    await announceJobEnded(db, job, "ready");
  });
}

/**
 * Ends a job as failed.
 *
 * Takes the reason as an argument so a caller that already knows *why* it is about to fail can say
 * so before it throws — a workflow step cannot call another step, and by the time the workflow's
 * catch runs the original error has been wrapped in the runtime's own "failed after N retries"
 * message.
 *
 * @param publicReason what the client shows. Left out, the client is told only that generation
 *   failed and that retrying is worth a try, which is the right answer for a provider that timed
 *   out and the wrong one for a request that will be refused the same way every time.
 */
export async function failJob(
  db: Database,
  jobId: string,
  message: string,
  publicReason?: string,
  options: { settlement?: SettlementSink } = {},
): Promise<void> {
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  traceEvent("failJobStep", { jobId, state: job?.state, message: message.slice(0, 200) });
  if (!job) return;
  if (job.state === "failed") return;
  const safeMessage = message.slice(0, 500);
  const failed = await db.transaction(async (tx) => {
    const now = new Date();
    const changed = await tx.update(generationJobs).set({
      state: "failed",
      errorCode: "GENERATION_FAILED",
      errorMessage: safeMessage,
      updatedAt: now,
      completedAt: now,
    }).where(and(eq(generationJobs.id, jobId), eq(generationJobs.state, "running"))).returning({ id: generationJobs.id });
    if (changed.length === 0) return false;
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "failed" }).where(and(
        eq(chatMessages.id, job.sourceMessageId),
        eq(chatMessages.jobId, job.id),
      ));
    }
    await tx.update(chatMessages).set({ status: "failed" }).where(and(
      eq(chatMessages.jobId, job.id),
      eq(chatMessages.role, "system"),
      eq(chatMessages.kind, "status"),
      eq(chatMessages.status, "streaming"),
    ));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "failed",
      dataJson: {
        code: "GENERATION_FAILED",
        message: publicReason ?? "Generation failed. You can retry this request.",
      },
      createdAt: now,
    });
    return true;
  });
  // Only the transition that actually happened announces itself — a late second call, or a job
  // something else already finished, stays silent. The refund is guarded the same way, so a
  // repeated call cannot release a hold that a different ending already settled.
  if (!failed) return;
  await pushLiveActivityUpdate(db, job.ownerId, jobId);
  await settle(options.settlement, async () => {
    await refundJobCredits(db, job, "generation_failed");
    await announceJobEnded(db, job, "failed");
  });
}
