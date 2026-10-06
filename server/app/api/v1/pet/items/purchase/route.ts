import { PurchasePetItemRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { buyPetItem } from "@/lib/services/pet-shop";
import { getPet } from "@/lib/services/pets";

/** Buys one of today's food or tickets into the pet's bag, to use later. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const input = await readJson(request, PurchasePetItemRequestSchema.parse);
    await buyPetItem(db, principal.sub, input);
    return noStoreJson(await getPet(db, principal.sub));
  });
}
