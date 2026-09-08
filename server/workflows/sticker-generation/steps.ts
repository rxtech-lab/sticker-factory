import { and, desc, eq } from "drizzle-orm";
import { FatalError } from "workflow";
import { withAiApiCostRecorder } from "@/lib/ai/cost";
import { firstRow, getDatabase, type Database } from "@/lib/db/client";
import { assets, chatMessages, chatThreads, generationEvents, generationJobs, stickers, type GenerationJobRow } from "@/lib/db/schema";
import { getAiProvider } from "@/lib/ai/gateway";
import { isNotifiableJobKind, notifyGenerationFinished, type GenerationOutcome } from "@/lib/notifications/generation";
import { describeError, traceEvent, traceSpan } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { acceptRevision, bindExports, rejectRevision, revertRevision } from "@/lib/services/stickers";
import { quickPublishSticker } from "@/lib/services/quick-publish";
import { getObjectStore } from "@/lib/storage/r2";
import { ApiError } from "@/lib/http/errors";
import { chargeJobCredits, recordJobApiCost, refundJobCredits } from "@/lib/subscription/credits";
import type { PublishExportsRequest } from "@/lib/contracts/api";
import { executeAiJob } from "./ai-turn";
import { MAX_SUMMARIZED_TITLE_LENGTH, beginJob, boundedTranscript } from "./turn-context";
import type { AiTurnResult } from "./turn-context";

// Every step boundary the workflow crosses. The bodies live in the sibling modules; what has
// to be here is the `"use step"` declaration itself, which is how the workflow compiler knows
// where the durable boundary is and what it may leave out of the workflow bundle.
export async function beginJobStep(jobId: string): Promise<void> {
  "use step";
  return beginJob(jobId);
}

export async function executeAiJobStep(jobId: string): Promise<AiTurnResult> {
  "use step";
  return executeAiJob(jobId);
}

/**
 * The server-rendered publish behind quick mode.
 *
 * A step rather than a request handler because it draws the whole export ladder — for an animated
 * sticker that is a few hundred librsvg rasterisations — and nothing that slow belongs on a
 * connection an iMessage extension is holding open. The extension starts the job and watches its
 * events like it watches a generation.
 *
 * `QuickPublishUnsupportedError` (and every other 4xx) fails the job once instead of retrying: a
 * document this renderer will not draw fails identically on every attempt, and the message is the
 * one the extension shows next to its "Open the main app" button.
 */
export async function quickPublishStep(jobId: string) {
  "use step";
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!job || (job.kind !== "export" && !(job.appClip && job.quick))) throw new Error("Export job not found");
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "rendering_exports", progress: 0.02 });
  try {
    // Reported as tool calls rather than as bare stages, because the surface watching a quick
    // publish is the same list that just drew the artwork: the export ladder is several slow
    // rasterisations, and one spinner for the lot of them says only that nothing has crashed.
    const result = await quickPublishSticker(db, job.ownerId, job.stickerId, async (step) => {
      await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
        toolCallId: `publish:${step.id}`,
        toolName: step.id,
        toolStatus: step.status === "complete" ? "complete" : "streaming",
        progress: step.progress,
      });
    });
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "verifying_exports", progress: 0.9 });
    return result;
  } catch (error) {
    if (!(error instanceof ApiError) || error.status >= 500) throw error;
    await failJob(db, jobId, error.message, error.message);
    throw new FatalError(error.message);
  }
}

export async function publishExportsStep(jobId: string, request: PublishExportsRequest) {
  "use step";
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!job || job.kind !== "export") throw new Error("Export job not found");
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "verifying_exports", progress: 0.5 });
  try {
    return await bindExports(db, job.ownerId, job.stickerId, request, job.id);
  } catch (error) {
    // A rejected rendition is a verdict on bytes that are already uploaded: the same file fails the
    // same way on every attempt, so retrying spends twenty seconds arriving back here. Fail once,
    // and hand the reason to the client — the sticker stays a draft either way, and "Generation
    // failed. You can retry this request." leaves someone pressing Publish forever.
    if (!(error instanceof ApiError) || error.status >= 500) throw error;
    await failJob(db, jobId, error.message, exportRejectionReason(error));
    throw new FatalError(error.message);
  }
}

/**
 * What the export sheet says when the server refuses a rendition.
 *
 * Only the timing codes get their own sentence, because only they describe a file the app produced
 * wrongly rather than something the person did: nothing about the sticker is broken, the build that
 * rendered it is. Everything else falls back to the server's own words, which is already more than
 * the client had.
 */
function exportRejectionReason(error: ApiError): string {
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
 * Trims a model's answer down to something a library row can show: one line, no wrapping quotes,
 * and short enough that the list never has to cut it off mid-word.
 *
 * Returns `undefined` for an answer with no name in it, which is the caller's signal to keep the
 * name the sticker already has.
 */
function normalizeStickerTitle(value: string): string | undefined {
  const single = value.replace(/\s+/g, " ").trim()
    .replace(/^["'“”‘’]+/, "")
    .replace(/["'“”‘’.]+$/, "")
    .trim();
  if (!single) return undefined;
  if (single.length <= MAX_SUMMARIZED_TITLE_LENGTH) return single;
  const clipped = single.slice(0, MAX_SUMMARIZED_TITLE_LENGTH);
  const lastSpace = clipped.lastIndexOf(" ");
  return (lastSpace >= MAX_SUMMARIZED_TITLE_LENGTH / 2 ? clipped.slice(0, lastSpace) : clipped).trim();
}

/**
 * Renames the sticker from what its chat has become.
 *
 * A sticker is born named after the first 64 characters the user typed, and nothing has renamed it
 * since — so a project that started as "make a cat with sunglasses please" carries that sentence
 * through the library, the notifications and the share sheet forever. This summarizes the transcript
 * into a short name instead, once per turn, and the provider is asked to repeat the current name
 * back whenever it still fits so an unchanged project stops churning.
 *
 * Nothing here can fail the turn: the artwork is what the user asked for, and a naming call that
 * times out must not turn a finished generation into a failed job. It runs before `completeJobStep`
 * because the client refetches the sticker when the job's stream ends, and this is the last moment
 * a new name can ride along on that fetch instead of waiting for the next time the library loads.
 */
export async function summarizeStickerTitleStep(jobId: string): Promise<string | undefined> {
  "use step";
  const db = await getDatabase();
  try {
    const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
    if (!job) return undefined;
    // Skipped for quick mode, and skipped in the one place that matters: this step runs *before*
    // the job is completed, so its model call sits between the finished artwork and the moment the
    // extension is told the turn is over. A sticker made in Messages is already named after the
    // prompt that made it, which is a worse name than the model would write and an immeasurably
    // better one than a name that arrives ten seconds late.
    if (job.quick) return undefined;
    const sticker = await db.select().from(stickers)
      .where(and(eq(stickers.id, job.stickerId), eq(stickers.ownerId, job.ownerId))).then(firstRow);
    if (!sticker || sticker.status === "deleting") return undefined;
    const thread = await db.select().from(chatThreads).where(eq(chatThreads.stickerId, sticker.id)).then(firstRow);
    if (!thread) return undefined;
    // Tool-call rows are the turn's machinery, not its content — a transcript of them would name the
    // sticker after the tools that drew it.
    const transcript = (await db.select().from(chatMessages).where(eq(chatMessages.threadId, thread.id))
      .orderBy(desc(chatMessages.sequence)).limit(40)).reverse()
      .filter((message) => message.kind !== "status");
    if (transcript.length === 0) return undefined;
    const proposed = await traceSpan("summarizeStickerTitle", { jobId }, () =>
      withAiApiCostRecorder(
        (event) => recordJobApiCost(db, jobId, event),
        () => getAiProvider().summarizeStickerTitle({
          currentTitle: sticker.title,
          history: boundedTranscript(transcript, 8_000),
          stickerKind: sticker.kind,
        }),
      ));
    const title = normalizeStickerTitle(proposed);
    if (!title || title === sticker.title) return undefined;
    await db.update(stickers).set({ title, updatedAt: new Date() })
      .where(and(eq(stickers.id, sticker.id), eq(stickers.ownerId, job.ownerId)));
    traceEvent("summarizeStickerTitle:renamed", { jobId, stickerId: sticker.id, title });
    return title;
  } catch (error) {
    traceEvent("summarizeStickerTitle:skipped", { jobId, error: describeError(error) });
    return undefined;
  }
}

/**
 * Sends the "this turn is over" banner, from the side that watched the turn.
 *
 * Called only after the terminal transition has actually committed, so a step that re-runs over an
 * already-finished job cannot announce it twice. Awaited rather than fired and forgotten: the
 * workflow step is the process, and a promise left dangling past its return is a push that never
 * leaves. `notifyGenerationFinished` swallows its own failures, so awaiting it is free of risk.
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

export async function completeJobStep(jobId: string, result: Record<string, unknown>): Promise<void> {
  "use step";
  return completeJob(jobId, result);
}

async function completeJob(jobId: string, result: Record<string, unknown>): Promise<void> {
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
  // The one path that actually charges. Everything else returns the hold.
  await chargeJobCredits(db, job);
  await announceJobEnded(db, job, "ready");
}

export async function failJobStep(jobId: string, message: string): Promise<void> {
  "use step";
  return failJob(await getDatabase(), jobId, message);
}

/**
 * Quick mode's complete generation lifecycle in one durable step.
 *
 * The ordinary workflow isolates begin, generation, title summarization, and completion so a long
 * app turn can resume between them. Quick already skips summarization and normally draws in a few
 * seconds; splitting its tiny lifecycle across four function invocations costs more wall time than
 * the image model. One step keeps automatic retries and replay while removing those handoffs.
 */
export async function quickGenerationStep(jobId: string): Promise<{
  workflowStatus: "succeeded";
  result: AiTurnResult;
}> {
  "use step";
  const queued = await (await getDatabase()).select({ quick: generationJobs.quick }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!queued?.quick) throw new Error("Quick generation step requires a Quick job");

  await beginJob(jobId);
  const result = await executeAiJob(jobId);
  await completeJob(jobId, result);
  return { workflowStatus: "succeeded", result };
}

/**
 * Ends a job as failed.
 *
 * Separate from `failJobStep` so a step that already knows *why* it is about to fail can say so
 * before it throws — a step cannot call another step, and by the time the workflow's catch runs the
 * original error has been wrapped in the runtime's own "failed after N retries" message.
 *
 * @param publicReason what the client shows. Left out, the client is told only that generation
 *   failed and that retrying is worth a try, which is the right answer for a provider that timed
 *   out and the wrong one for a request that will be refused the same way every time.
 */
async function failJob(db: Database, jobId: string, message: string, publicReason?: string): Promise<void> {
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
  if (failed) {
    await refundJobCredits(db, job, "generation_failed");
    await announceJobEnded(db, job, "failed");
  }
}

export async function purgeStickerStep(jobId: string): Promise<string[]> {
  "use step";
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!job || job.kind !== "cleanup") throw new Error("Cleanup job not found");
  const objectStore = getObjectStore();
  const rows = await db.select().from(assets).where(and(eq(assets.stickerId, job.stickerId), eq(assets.ownerId, job.ownerId)));
  for (const asset of rows) await objectStore.delete(asset.r2Key);
  return rows.map((asset) => asset.r2Key);
}

export async function sweepStickerObjectsStep(objectKeys: string[]): Promise<void> {
  "use step";
  const objectStore = getObjectStore();
  for (const key of objectKeys) await objectStore.delete(key);
}

export async function finalizeStickerPurgeStep(jobId: string): Promise<void> {
  "use step";
  const db = await getDatabase();
  const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  if (!job || job.kind !== "cleanup") throw new Error("Cleanup job not found");
  await db.delete(stickers).where(and(
    eq(stickers.id, job.stickerId),
    eq(stickers.ownerId, job.ownerId),
    eq(stickers.status, "deleting"),
  ));
}


export type RevisionDecisionInput = {
  ownerId: string;
  stickerId: string;
  revisionId: string;
  decision: "accept" | "reject" | "revert";
  decisionId: string;
};

export async function decideRevisionStep(input: RevisionDecisionInput) {
  "use step";
  const db = await getDatabase();
  if (input.decision === "accept") return acceptRevision(db, input.ownerId, input.stickerId, input.revisionId);
  if (input.decision === "reject") return rejectRevision(db, input.ownerId, input.stickerId, input.revisionId);
  return revertRevision(db, input.ownerId, input.stickerId, input.revisionId, input.decisionId);
}

export type { AiTurnResult } from "./turn-context";
