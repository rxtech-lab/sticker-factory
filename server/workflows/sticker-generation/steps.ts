import { and, desc, eq } from "drizzle-orm";
import { FatalError } from "workflow";
import { withAiApiCostRecorder } from "@/lib/ai/cost";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, chatThreads, generationJobs, stickers } from "@/lib/db/schema";
import { getAiProvider } from "@/lib/ai/gateway";
import { describeError, traceEvent, traceSpan } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { exportRejectionReason } from "@/lib/services/export-publish";
import { beginJob, completeJob, failJob } from "@/lib/services/job-lifecycle";
import { acceptRevision, bindExports, rejectRevision, revertRevision } from "@/lib/services/stickers";
import { quickPublishSticker } from "@/lib/services/quick-publish";
import { getObjectStore } from "@/lib/storage/r2";
import { ApiError } from "@/lib/http/errors";
import { recordJobApiCost } from "@/lib/subscription/credits";
import type { PublishExportsRequest } from "@/lib/contracts/api";
import { executeAiJob } from "./ai-turn";
import { MAX_SUMMARIZED_TITLE_LENGTH, boundedTranscript } from "./turn-context";
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
    const startedAt = Date.now();
    const result = await bindExports(db, job.ownerId, job.stickerId, request, job.id);
    traceEvent("publishExportsStep:bound", { jobId, ms: Date.now() - startedAt });
    return result;
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

export async function completeJobStep(jobId: string, result: Record<string, unknown>): Promise<void> {
  "use step";
  return completeJob(jobId, result);
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
