import { after } from "next/server";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetRooms, refreshPetRoomOffers } from "@/lib/services/pet-rooms";

// Restocking the shop designs and draws several rooms after the response.
export const maxDuration = 300;

/**
 * The owner's rooms, the room shop's offers, and the room the pet lives in. A shop that is due new
 * rooms starts drawing them after the response; `drawing` says so, and a later read carries them.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    after(() => refreshPetRoomOffers(db, principal.sub));
    return noStoreJson({ rooms: await listPetRooms(db, principal.sub) });
  });
}
