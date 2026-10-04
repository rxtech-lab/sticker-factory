import { sleep } from "workflow";
import { planPetVisitStep, retirePetLifeStep, visitPetStep } from "@/workflows/pet-life/steps";

/**
 * Visits per run. At 3–7 hours apart this is about a week; then the run retires and the hourly
 * cron starts a fresh one, so no single run's history grows without end.
 */
const VISITS_PER_RUN = 28;

/**
 * The pet's life while its owner is away: sleep a few hours, then a visit — the weather and the
 * owner's steps are read, headlines searched, a special event rolled — and again.
 *
 * Ends as soon as the pet is released or replaced, or another run takes over its token.
 */
export async function petLifeWorkflow(userId: string, lifeId: string, token: string) {
  "use workflow";
  for (let visit = 0; visit < VISITS_PER_RUN; visit += 1) {
    const delayMs = await planPetVisitStep(userId, lifeId, token);
    if (delayMs === null) return { ended: "replaced" as const, visits: visit };
    await sleep(delayMs);
    if (!await visitPetStep(userId, lifeId, token)) return { ended: "replaced" as const, visits: visit + 1 };
  }
  await retirePetLifeStep(userId, lifeId, token);
  return { ended: "retired" as const, visits: VISITS_PER_RUN };
}
