import type { PublishExportsRequest } from "@/lib/contracts/api";
import { sleep } from "workflow";
import {
  beginJobStep,
  completeJobStep,
  decideRevisionStep,
  executeAiJobStep,
  failJobStep,
  finalizeStickerPurgeStep,
  publishExportsStep,
  purgeStickerStep,
  sweepStickerObjectsStep,
  type RevisionDecisionInput,
} from "@/workflows/sticker-generation/steps";

export async function stickerGenerationWorkflow(jobId: string) {
  "use workflow";
  await beginJobStep(jobId);
  try {
    const result = await executeAiJobStep(jobId);
    await completeJobStep(jobId, result);
    return { workflowStatus: "succeeded" as const, result };
  } catch (error) {
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
