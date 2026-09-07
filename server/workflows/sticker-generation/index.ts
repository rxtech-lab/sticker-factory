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
  quickGenerationStep,
  quickPublishStep,
  summarizeStickerTitleStep,
  sweepStickerObjectsStep,
  type AiTurnResult,
  type RevisionDecisionInput,
} from "@/workflows/sticker-generation/steps";

type StickerGenerationWorkflowResult =
  | { workflowStatus: "succeeded"; result: AiTurnResult }
  | { workflowStatus?: undefined; status: "failed" };

export async function stickerGenerationWorkflow(
  jobId: string,
  quick = false,
  appClip = false,
): Promise<StickerGenerationWorkflowResult> {
  "use workflow";
  if (appClip) {
    await beginJobStep(jobId);
    try {
      const result = await executeAiJobStep(jobId);
      // Separate durable steps: publication retries never redraw or spend another allowance.
      await quickPublishStep(jobId);
      await completeJobStep(jobId, result);
      return { workflowStatus: "succeeded" as const, result };
    } catch (error) {
      await failJobStep(jobId, error instanceof Error ? error.message : String(error));
      return { status: "failed" as const };
    }
  }
  if (quick) {
    try {
      return await quickGenerationStep(jobId);
    } catch (error) {
      console.error("[gen] stickerGenerationWorkflow:quickFailed", { jobId, error: describeError(error) });
      await failJobStep(jobId, error instanceof Error ? error.message : String(error));
      return { status: "failed" as const };
    }
  }
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

/**
 * Quick mode's publish: the server draws the renditions and binds them itself.
 *
 * Deliberately the same shape as `stickerExportWorkflow` — same job kind, same events, same
 * terminal states — so the clients that already watch a publish need to learn nothing new about
 * this one.
 */
export async function stickerQuickPublishWorkflow(jobId: string) {
  "use workflow";
  await beginJobStep(jobId);
  try {
    const result = await quickPublishStep(jobId);
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
