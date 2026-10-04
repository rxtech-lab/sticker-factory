import { SetPetRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { clearPet, getPet, setPet } from "@/lib/services/pets";

/**
 * The controllable sticker the caller has adopted as their pet.
 *
 * Not idempotency-keyed: choosing the same pet twice, or clearing an empty slot, already lands on
 * the same state, so a retried request cannot do anything a first one would not.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => noStoreJson(await getPet(db, principal.sub)));
}

export async function PUT(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SetPetRequestSchema.parse);
    return noStoreJson(await setPet(db, principal.sub, body));
  });
}

export async function DELETE(request: Request) {
  return withApiAuth(request, async (principal, db) => noStoreJson(await clearPet(db, principal.sub)));
}
