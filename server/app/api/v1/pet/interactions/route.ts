import { PetInteractionRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { interactWithPet } from "@/lib/services/pets";

/** A direct action on the account's current pet, with its model-written response. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, PetInteractionRequestSchema.parse);
    return noStoreJson(await interactWithPet(db, principal.sub, body));
  });
}
