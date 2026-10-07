import { RememberPetTalkRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { rememberPetTalk } from "@/lib/services/pet-memory";
import { posePetForTalk } from "@/lib/services/pet-talk";
import { getPet } from "@/lib/services/pets";

/**
 * Something the owner said to their pet and its answer: the pet's memory agent remembers it, and
 * the decision model poses the pet to match. Answers with the posed pet; a pose that fails leaves
 * the pet as it was.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, RememberPetTalkRequestSchema.parse);
    await rememberPetTalk(db, principal.sub, body);
    const { pet } = await posePetForTalk(db, principal.sub, body).catch(async (error) => {
      traceEvent("pet.talk:pose:failed", { userId: principal.sub, error: describeError(error) });
      return getPet(db, principal.sub);
    });
    return noStoreJson({ accepted: true, pet });
  });
}
