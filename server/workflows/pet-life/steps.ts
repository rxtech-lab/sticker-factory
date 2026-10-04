import { getDatabase } from "@/lib/db/client";
import { planPetVisit, retirePetLife, visitPet } from "@/lib/services/pet-life";

// Thin steps over `lib/services/pet-life.ts`, which holds the logic and the tests. Each is its own
// durable unit: a crash mid-visit retries the visit, never the sleep before it.

export async function planPetVisitStep(userId: string, lifeId: string, token: string): Promise<number | null> {
  "use step";
  return planPetVisit(await getDatabase(), userId, lifeId, token);
}

export async function visitPetStep(userId: string, lifeId: string, token: string): Promise<boolean> {
  "use step";
  return visitPet(await getDatabase(), userId, lifeId, token);
}

export async function retirePetLifeStep(userId: string, lifeId: string, token: string): Promise<void> {
  "use step";
  await retirePetLife(await getDatabase(), userId, lifeId, token);
}
