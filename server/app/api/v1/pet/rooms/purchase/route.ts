import { PurchasePetRoomRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetRooms, purchasePetRoom } from "@/lib/services/pet-rooms";
import { getPet } from "@/lib/services/pets";

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
    return noStoreJson({ pet: (await getPet(db, principal.sub)).pet, rooms: await listPetRooms(db, principal.sub) });
  });
}
