import { SetPetRoomRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetRooms, movePetToRoom } from "@/lib/services/pet-rooms";
import { getPet } from "@/lib/services/pets";

/** Moves the pet into a room the owner has, or back onto the plain page. Repeating it changes nothing. */
export async function PUT(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SetPetRoomRequestSchema.parse);
    await movePetToRoom(db, principal.sub, body.roomId);
    return noStoreJson({ pet: (await getPet(db, principal.sub)).pet, rooms: await listPetRooms(db, principal.sub) });
  });
}
