import { sleep } from "workflow";
import {
  beginPetFriendPlanStep,
  confirmPetFriendPlanStep,
  failPetFriendStep,
  finishPetFriendStep,
  petFriendJobStateStep,
  publishPetFriendStep,
} from "@/workflows/pet-friend/steps";

/** How often a stage's generation job is looked at while the pet waits on it. */
const POLL_MS = 20_000;
/** Planning draws a concept; building draws sprite sheets. Both are minutes, never an hour. */
const PLAN_LIMIT_MS = 20 * 60 * 1000;
const BUILD_LIMIT_MS = 45 * 60 * 1000;

/**
 * The pet's new friend becoming a sticker: plan it as a new controllable sticker, build it, publish
 * it, then let the pet introduce them. The generation jobs run in their own workflow runs, as the
 * owner's turns do; this run only starts each one and waits for it to end.
 *
 * Ends quietly as soon as the friend is no longer being made.
 */
export async function petFriendWorkflow(userId: string, friendId: string) {
  "use workflow";
  try {
    const planJobId = await beginPetFriendPlanStep(userId, friendId);
    if (!planJobId) return { ended: "gone" as const };
    await waitForJob(planJobId, PLAN_LIMIT_MS);
    const composeJobId = await confirmPetFriendPlanStep(userId, friendId);
    if (!composeJobId) return { ended: "gone" as const };
    await waitForJob(composeJobId, BUILD_LIMIT_MS);
    if (!await publishPetFriendStep(userId, friendId)) return { ended: "gone" as const };
    await finishPetFriendStep(userId, friendId);
    return { ended: "met" as const };
  } catch (error) {
    await failPetFriendStep(userId, friendId, error instanceof Error ? error.message : String(error));
    return { ended: "failed" as const };
  }
}

async function waitForJob(jobId: string, limitMs: number): Promise<void> {
  for (let waited = 0; waited < limitMs; waited += POLL_MS) {
    await sleep(POLL_MS);
    const state = await petFriendJobStateStep(jobId);
    if (state === "succeeded") return;
    if (state === null || state === "failed" || state === "cancelled") throw new Error(`Friend job ${jobId} ended ${state ?? "missing"}`);
  }
  throw new Error(`Friend job ${jobId} did not finish in time`);
}
