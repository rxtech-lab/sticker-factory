import { after } from "next/server";
import { PurchasePetRoomRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetRooms, purchasePetRoom } from "@/lib/services/pet-rooms";
import { drawPetWeatherArt } from "@/lib/services/pet-weather";
import { getPet } from "@/lib/services/pets";

// Moving in draws the sky outside the new window in the background.
export const maxDuration = 300;

/**
 * Buys a room from the shop with the owner's gold and moves the pet in.
 *
 * Not idempotency-keyed: the room is claimed before the gold moves, so a retried purchase is
 * refused as already owned rather than paid for twice.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, PurchasePetRoomRequestSchema.parse);
    await purchasePetRoom(db, principal.sub, body.roomId);
    // The sky outside its window, drawn in the pet's style if this look is new; the next read carries it.
    after(() => drawPetWeatherArt(db, principal.sub));
    return noStoreJson({ pet: (await getPet(db, principal.sub)).pet, rooms: await listPetRooms(db, principal.sub) });
  });
}
