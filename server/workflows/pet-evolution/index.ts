import { sleep } from "workflow";
import {
  beginPetEvolutionPlanStep,
  confirmPetEvolutionPlanStep,
  failPetEvolutionStep,
  finishPetEvolutionStep,
  petEvolutionJobStateStep,
  publishPetEvolutionStep,
} from "@/workflows/pet-evolution/steps";

/** How often a stage's generation job is looked at while the pet waits on it. */
const POLL_MS = 20_000;
/** Planning draws a concept; building redraws sprite sheets. Both are minutes, never an hour. */
const PLAN_LIMIT_MS = 20 * 60 * 1000;
const BUILD_LIMIT_MS = 45 * 60 * 1000;

/**
 * The pet growing a new mood, property or look: plan it on the pet's own sticker, build it, publish
 * it, then let the pet tell its owner. The generation jobs run in their own workflow runs, as the
 * owner's turns do; this run only starts each one and waits for it to end.
 *
 * Ends quietly as soon as the pet is released or replaced, or the evolution is no longer this one.
 */
export async function petEvolutionWorkflow(userId: string, evolutionId: string) {
  "use workflow";
  try {
    const planJobId = await beginPetEvolutionPlanStep(userId, evolutionId);
    if (!planJobId) return { ended: "replaced" as const };
    await waitForJob(planJobId, PLAN_LIMIT_MS);
    const composeJobId = await confirmPetEvolutionPlanStep(userId, evolutionId);
    if (!composeJobId) return { ended: "replaced" as const };
    await waitForJob(composeJobId, BUILD_LIMIT_MS);
    if (!await publishPetEvolutionStep(userId, evolutionId)) return { ended: "replaced" as const };
    await finishPetEvolutionStep(userId, evolutionId);
    return { ended: "evolved" as const };
  } catch (error) {
    await failPetEvolutionStep(userId, evolutionId, error instanceof Error ? error.message : String(error));
    return { ended: "failed" as const };
  }
}

async function waitForJob(jobId: string, limitMs: number): Promise<void> {
  for (let waited = 0; waited < limitMs; waited += POLL_MS) {
    await sleep(POLL_MS);
    const state = await petEvolutionJobStateStep(jobId);
    if (state === "succeeded") return;
    if (state === null || state === "failed" || state === "cancelled") throw new Error(`Evolution job ${jobId} ended ${state ?? "missing"}`);
  }
  throw new Error(`Evolution job ${jobId} did not finish in time`);
}
