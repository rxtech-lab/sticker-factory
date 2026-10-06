import { after } from "next/server";
import { PetContextV1Schema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { updatePetContext } from "@/lib/services/pets";

// A phone far from home has the pet's agent discover and draw a place on the trip after the response.
export const maxDuration = 300;

/**
 * The phone's coarse context — rounded location, steps today, time zone — for the pet's life
 * workflow to read on its next visit. Sent when the app comes forward and after the user connects
 * Health or Location, and in the background as the owner travels while tracking is on; the signals are
 * re-read right after the response so the Pet tab shows them now. `trackLocation: false` forgets where
 * the owner was.
 */
export async function PUT(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, PetContextV1Schema.parse);
    return noStoreJson(await updatePetContext(db, principal.sub, body, (task) => after(task)));
  });
}
