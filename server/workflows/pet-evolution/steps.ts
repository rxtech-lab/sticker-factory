import { getDatabase } from "@/lib/db/client";
import {
  beginPetEvolutionPlan,
  confirmPetEvolutionPlan,
  failPetEvolution,
  finishPetEvolution,
  petEvolutionJobState,
  publishPetEvolution,
} from "@/lib/services/pet-evolution";

// Thin steps over `lib/services/pet-evolution.ts`, which holds the logic and the tests. Each stage is
// its own durable unit: a crash while publishing retries the publish, never the plan or the build.

export async function beginPetEvolutionPlanStep(userId: string, evolutionId: string): Promise<string | null> {
  "use step";
  return beginPetEvolutionPlan(await getDatabase(), userId, evolutionId);
}

export async function petEvolutionJobStateStep(jobId: string): Promise<string | null> {
  "use step";
  return petEvolutionJobState(await getDatabase(), jobId);
}

export async function confirmPetEvolutionPlanStep(userId: string, evolutionId: string): Promise<string | null> {
  "use step";
  return confirmPetEvolutionPlan(await getDatabase(), userId, evolutionId);
}

export async function publishPetEvolutionStep(userId: string, evolutionId: string): Promise<boolean> {
  "use step";
  return publishPetEvolution(await getDatabase(), userId, evolutionId);
}

export async function finishPetEvolutionStep(userId: string, evolutionId: string): Promise<boolean> {
  "use step";
  return finishPetEvolution(await getDatabase(), userId, evolutionId);
}

export async function failPetEvolutionStep(userId: string, evolutionId: string, message: string): Promise<void> {
  "use step";
  await failPetEvolution(await getDatabase(), userId, evolutionId, message);
}
