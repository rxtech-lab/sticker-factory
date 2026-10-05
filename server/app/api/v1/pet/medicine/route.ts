import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { givePetMedicine } from "@/lib/services/pet-encounters";
import { getPet } from "@/lib/services/pets";

/** Gives the ill pet one dose of medicine, curing it. Refused while it is well or has none. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    await givePetMedicine(db, principal.sub);
    return noStoreJson(await getPet(db, principal.sub));
  });
}
