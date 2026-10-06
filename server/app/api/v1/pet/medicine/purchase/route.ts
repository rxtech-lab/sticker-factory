import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { buyPetMedicine } from "@/lib/services/pet-shop";
import { getPet } from "@/lib/services/pets";

/** Buys a dose of medicine from the item shop, kept until the pet needs it. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    await buyPetMedicine(db, principal.sub);
    return noStoreJson(await getPet(db, principal.sub));
  });
}
