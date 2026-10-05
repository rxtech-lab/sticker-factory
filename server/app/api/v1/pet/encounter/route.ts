import { ResolvePetEncounterRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { resolvePetEncounter } from "@/lib/services/pet-encounters";
import { getPet } from "@/lib/services/pets";

/**
 * The owner's pick for the pet's open encounter: what it led to, and the pet after it.
 *
 * Not idempotency-keyed: the encounter is claimed before anything lands, so a retried pick is
 * refused as already decided rather than applied twice.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, ResolvePetEncounterRequestSchema.parse);
    const outcome = await resolvePetEncounter(db, principal.sub, body);
    return noStoreJson({ outcome, pet: (await getPet(db, principal.sub)).pet });
  });
}
