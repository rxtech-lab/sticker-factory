import { MarkPetFriendSeenRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { markPetFriendSeen } from "@/lib/services/pet-friends";
import { getPet } from "@/lib/services/pets";

/**
 * The owner has been welcomed to the friend their pet made: it leaves the pet, and the pet after it.
 * Safe to repeat — a friend already seen stays seen.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, MarkPetFriendSeenRequestSchema.parse);
    await markPetFriendSeen(db, principal.sub, body.friendId);
    return noStoreJson(await getPet(db, principal.sub));
  });
}
