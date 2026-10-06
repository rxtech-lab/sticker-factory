import { getDatabase } from "@/lib/db/client";
import {
  beginPetFriendPlan,
  confirmPetFriendPlan,
  failPetFriend,
  finishPetFriend,
  petFriendJobState,
  publishPetFriend,
} from "@/lib/services/pet-friends";

// Thin steps over `lib/services/pet-friends.ts`, which holds the logic and the tests. Each stage is
// its own durable unit: a crash while publishing retries the publish, never the plan or the build.

export async function beginPetFriendPlanStep(userId: string, friendId: string): Promise<string | null> {
  "use step";
  return beginPetFriendPlan(await getDatabase(), userId, friendId);
}

export async function petFriendJobStateStep(jobId: string): Promise<string | null> {
  "use step";
  return petFriendJobState(await getDatabase(), jobId);
}

export async function confirmPetFriendPlanStep(userId: string, friendId: string): Promise<string | null> {
  "use step";
  return confirmPetFriendPlan(await getDatabase(), userId, friendId);
}

export async function publishPetFriendStep(userId: string, friendId: string): Promise<boolean> {
  "use step";
  return publishPetFriend(await getDatabase(), userId, friendId);
}

export async function finishPetFriendStep(userId: string, friendId: string): Promise<boolean> {
  "use step";
  return finishPetFriend(await getDatabase(), userId, friendId);
}

export async function failPetFriendStep(userId: string, friendId: string, message: string): Promise<void> {
  "use step";
  await failPetFriend(await getDatabase(), userId, friendId, message);
}
