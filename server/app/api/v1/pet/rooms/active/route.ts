import { after } from "next/server";
import { SetPetRoomRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetRooms, movePetToRoom } from "@/lib/services/pet-rooms";
import { drawPetWeatherArt } from "@/lib/services/pet-weather";
import { getPet } from "@/lib/services/pets";

// Moving in draws the sky outside the new window in the background.
export const maxDuration = 300;

/** Moves the pet into a room the owner has, or back onto the plain page. Repeating it changes nothing. */
export async function PUT(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SetPetRoomRequestSchema.parse);
    await movePetToRoom(db, principal.sub, body.roomId);
    // The sky outside its window, drawn in the pet's style if this look is new; the next read carries it.
    after(() => drawPetWeatherArt(db, principal.sub));
    return noStoreJson({ pet: (await getPet(db, principal.sub)).pet, rooms: await listPetRooms(db, principal.sub) });
  });
}
