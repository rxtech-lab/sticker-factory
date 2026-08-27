import type { PublishExportsRequest } from "@/lib/contracts/api";
import { sleep } from "workflow";
import { describeError } from "@/lib/observability/trace";
import {
  beginJobStep,
  completeJobStep,
  decideRevisionStep,
  executeAiJobStep,
  failJobStep,
  finalizeStickerPurgeStep,
  publishExportsStep,
  purgeStickerStep,
  summarizeStickerTitleStep,
  sweepStickerObjectsStep,
  type RevisionDecisionInput,
} from "@/workflows/sticker-generation/steps";

export async function stickerGenerationWorkflow(jobId: string) {
  "use workflow";
  await beginJobStep(jobId);
  try {
    const result = await executeAiJobStep(jobId);
    // Between the turn and its completion on purpose: the client refetches the sticker when the
    // job's stream ends, so a name settled here arrives with the turn rather than a load later.
    // The step swallows its own failures, so it can only delay a turn, never fail one.
    await summarizeStickerTitleStep(jobId);
    await completeJobStep(jobId, result);
    return { workflowStatus: "succeeded" as const, result };
  } catch (error) {
    // The message is all `failJobStep` stores, and a wrapped SDK error's message says nothing about
    // what actually failed. The full chain only exists here, so print it before it is thrown away.
    console.error("[gen] stickerGenerationWorkflow:failed", { jobId, error: describeError(error) });
    await failJobStep(jobId, error instanceof Error ? error.message : String(error));
    return { status: "failed" as const };
  }
}

export async function revisionDecisionWorkflow(input: RevisionDecisionInput) {
  "use workflow";
  return decideRevisionStep(input);
}

export async function stickerExportWorkflow(jobId: string, request: PublishExportsRequest) {
  "use workflow";
  await beginJobStep(jobId);
  try {
    const result = await publishExportsStep(jobId, request);
    await completeJobStep(jobId, result);
    return { workflowStatus: "succeeded" as const, result };
  } catch (error) {
    await failJobStep(jobId, error instanceof Error ? error.message : String(error));
    return { status: "failed" as const };
  }
}

export async function stickerCleanupWorkflow(jobId: string, sweepDelayMs = 11 * 60 * 1000) {
  "use workflow";
  await beginJobStep(jobId);
  try {
    const objectKeys = await purgeStickerStep(jobId);
    if (sweepDelayMs > 0) await sleep(sweepDelayMs);
    await sweepStickerObjectsStep(objectKeys);
    await finalizeStickerPurgeStep(jobId);
    return { status: "succeeded" as const };
  } catch (error) {
    await failJobStep(jobId, error instanceof Error ? error.message : String(error));
    return { status: "failed" as const };
  }
}
