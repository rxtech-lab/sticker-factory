import { and, eq, inArray } from "drizzle-orm";
import { getRun, start } from "workflow/api";
import type { PublishExportsRequest } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { chatMessages, generationEvents, generationJobs, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  stickerCleanupWorkflow,
  stickerExportWorkflow,
  stickerGenerationWorkflow,
  revisionDecisionWorkflow,
} from "@/workflows/sticker-generation";
import type { RevisionDecisionInput } from "@/workflows/sticker-generation/steps";

async function recordRun(db: Database, jobId: string, runId: string) {
  await db.update(generationJobs).set({ workflowRunId: runId, updatedAt: new Date() })
    .where(eq(generationJobs.id, jobId));
}

async function recordDispatchFailure(db: Database, jobId: string): Promise<void> {
  await db.transaction(async (tx) => {
    const job = await tx.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
    if (!job || job.state === "failed") return;
    const now = new Date();
    await tx.update(generationJobs).set({
      state: "failed",
      errorCode: "WORKFLOW_DISPATCH_FAILED",
      errorMessage: "The durable workflow could not be dispatched. Retry the request.",
      updatedAt: now,
      completedAt: now,
    }).where(eq(generationJobs.id, jobId));
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "failed" }).where(and(
        eq(chatMessages.id, job.sourceMessageId),
        eq(chatMessages.jobId, job.id),
      ));
    }
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "failed",
      dataJson: { code: "WORKFLOW_DISPATCH_FAILED" },
      createdAt: now,
    });
  });
}

async function recordCleanupDispatchFailure(db: Database, jobId: string): Promise<void> {
  const now = new Date();
  await db.transaction(async (tx) => {
    const job = await tx.select().from(generationJobs).where(eq(generationJobs.id, jobId)).get();
    if (!job) return;
    await tx.update(generationJobs).set({
      state: "failed",
      errorCode: "WORKFLOW_DISPATCH_FAILED",
      errorMessage: "The durable cleanup workflow could not be dispatched. Retry deletion.",
      updatedAt: now,
      completedAt: now,
    }).where(eq(generationJobs.id, jobId));
    await tx.update(stickers).set({
      status: job.priorStickerStatus ?? "draft",
      deletedAt: null,
      updatedAt: now,
    }).where(and(
      eq(stickers.id, job.stickerId),
      eq(stickers.ownerId, job.ownerId),
      eq(stickers.status, "deleting"),
    ));
    await tx.insert(generationEvents).values({
      jobId,
      ownerId: job.ownerId,
      type: "failed",
      dataJson: { code: "WORKFLOW_DISPATCH_FAILED" },
      createdAt: now,
    });
  });
}

async function safelyRecordRun(db: Database, jobId: string, runId: string): Promise<void> {
  try { await recordRun(db, jobId, runId); } catch (error) {
    console.error("Workflow was dispatched but its run ID could not be recorded", { jobId, runId, error });
  }
}

export async function startGenerationWorkflow(db: Database, jobId: string): Promise<string> {
  if (process.env.NODE_ENV === "test" && process.env.STICKER_FACTORY_INLINE_WORKFLOWS === "true") {
    void stickerGenerationWorkflow(jobId);
    return `inline_${jobId}`;
  }
  try {
    const run = await start(stickerGenerationWorkflow, [jobId]);
    await safelyRecordRun(db, jobId, run.runId);
    return run.runId;
  } catch (error) {
    await recordDispatchFailure(db, jobId);
    throw error;
  }
}

export async function cancelGenerationWorkflow(db: Database, ownerId: string, jobId: string) {
  const job = await db.select().from(generationJobs).where(and(
    eq(generationJobs.id, jobId),
    eq(generationJobs.ownerId, ownerId),
  )).get();
  if (!job) throw new ApiError(404, "JOB_NOT_FOUND", "Generation job not found");
  // `compose` belongs here as much as any of the others: building a confirmed plan is the longest
  // turn the app runs, so it is the one a user is most likely to want to stop.
  if (!new Set(["image", "edit", "animation", "chat", "plan", "compose"]).has(job.kind)) {
    throw new ApiError(409, "JOB_NOT_CANCELLABLE", "Only an active sticker chat turn can be stopped");
  }
  if (!new Set(["queued", "running", "waiting"]).has(job.state)) {
    return { jobId, state: job.state };
  }

  const now = new Date();
  const cancelled = await db.transaction(async (tx) => {
    const changed = await tx.update(generationJobs).set({
      state: "cancelled",
      errorCode: "USER_CANCELLED",
      errorMessage: "Stopped by user",
      updatedAt: now,
      completedAt: now,
    }).where(and(
      eq(generationJobs.id, jobId),
      eq(generationJobs.ownerId, ownerId),
      inArray(generationJobs.state, ["queued", "running", "waiting"]),
    )).returning({ id: generationJobs.id });
    if (changed.length === 0) return false;
    if (job.sourceMessageId) {
      await tx.update(chatMessages).set({ status: "complete" }).where(and(
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
      ownerId,
      type: "completed",
      dataJson: { cancelled: true, message: "Stopped" },
      createdAt: now,
    });
    return true;
  });

  if (cancelled && job.workflowRunId && !job.workflowRunId.startsWith("inline_")) {
    try {
      await getRun(job.workflowRunId).cancel();
    } catch (error) {
      // The database transition is the source of truth and blocks any late
      // workflow write. A run may already have reached a terminal state here.
      console.warn("Could not cancel an already-stopped workflow run", { jobId, workflowRunId: job.workflowRunId, error });
    }
  }
  const finalState = cancelled
    ? "cancelled" as const
    : (await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, jobId)).get())?.state ?? job.state;
  return { jobId, state: finalState };
}

export async function startExportWorkflow(db: Database, jobId: string, request: PublishExportsRequest): Promise<string> {
  if (process.env.NODE_ENV === "test" && process.env.STICKER_FACTORY_INLINE_WORKFLOWS === "true") {
    void stickerExportWorkflow(jobId, request);
    return `inline_${jobId}`;
  }
  try {
    const run = await start(stickerExportWorkflow, [jobId, request]);
    await safelyRecordRun(db, jobId, run.runId);
    return run.runId;
  } catch (error) {
    await recordDispatchFailure(db, jobId);
    throw error;
  }
}

export async function startCleanupWorkflow(db: Database, jobId: string): Promise<string> {
  if (process.env.NODE_ENV === "test" && process.env.STICKER_FACTORY_INLINE_WORKFLOWS === "true") {
    void stickerCleanupWorkflow(jobId, process.env.NODE_ENV === "test" ? 0 : undefined);
    return `inline_${jobId}`;
  }
  try {
    const run = await start(stickerCleanupWorkflow, [jobId]);
    await safelyRecordRun(db, jobId, run.runId);
    return run.runId;
  } catch (error) {
    await recordCleanupDispatchFailure(db, jobId);
    throw error;
  }
}

export async function runRevisionDecisionWorkflow(input: RevisionDecisionInput) {
  if (process.env.NODE_ENV === "test" && process.env.STICKER_FACTORY_INLINE_WORKFLOWS === "true") {
    return revisionDecisionWorkflow(input);
  }
  const run = await start(revisionDecisionWorkflow, [input]);
  return run.returnValue;
}
