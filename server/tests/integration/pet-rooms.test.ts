import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { PetResponseV1Schema, PetRoomsV1Schema } from "@/lib/contracts/api";
import { userWallets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { setPetRandomForTests } from "@/lib/pets/log";
import { ROOM_OFFER_COUNT, ROOM_OFFER_LIFETIME_MS, roomPriceRange } from "@/lib/pets/rooms";
import { getPetRoomArt, listPetRooms, movePetToRoom, purchasePetRoom, refreshPetRoomOffers } from "@/lib/services/pet-rooms";
import { listPetEvents } from "@/lib/services/pet-state";
import { getPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("pet rooms", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setAiProviderForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const loaf = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    await setPet(db, "owner", { stickerId: loaf.stickerId });
    return { db, close };
  }

  async function expectApiError(promise: Promise<unknown>, code: string) {
    const error = await promise.catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).code).toBe(code);
  }

  it("stocks the shop once a day with fairly priced, drawn rooms", async () => {
    const { db, close } = await setup();
    try {
      const now = new Date();
      expect((await listPetRooms(db, "owner", now)).drawing).toBe(true);
      await refreshPetRoomOffers(db, "owner", now);
      const rooms = PetRoomsV1Schema.parse(await listPetRooms(db, "owner", now));
      expect(rooms.drawing).toBe(false);
      expect(rooms.owned).toEqual([]);
      expect(rooms.offers).toHaveLength(ROOM_OFFER_COUNT);
      for (const offer of rooms.offers) {
        const { min, max } = roomPriceRange(offer.effects);
        expect(offer.price).toBeGreaterThanOrEqual(min);
        expect(offer.price).toBeLessThanOrEqual(max);
        const art = await getPetRoomArt(db, "owner", offer.id);
        expect(art.bytes?.length).toBeGreaterThan(0);
        expect((await getPetRoomArt(db, "owner", offer.id, art.etag)).bytes).toBeNull();
      }

      // Within the day the shop keeps its rooms; after it, unsold ones make way for new ones.
      await refreshPetRoomOffers(db, "owner", new Date(now.getTime() + ROOM_OFFER_LIFETIME_MS - 1));
      expect((await listPetRooms(db, "owner")).offers.map((offer) => offer.id)).toEqual(rooms.offers.map((offer) => offer.id));
      await refreshPetRoomOffers(db, "owner", new Date(now.getTime() + ROOM_OFFER_LIFETIME_MS));
      const restocked = await listPetRooms(db, "owner", new Date(now.getTime() + ROOM_OFFER_LIFETIME_MS));
      expect(restocked.offers).toHaveLength(ROOM_OFFER_COUNT);
      expect(restocked.offers.some((offer) => rooms.offers.some((old) => old.id === offer.id))).toBe(false);
      await expectApiError(getPetRoomArt(db, "owner", rooms.offers[0].id), "PET_ROOM_NOT_FOUND");
    } finally {
      await close();
    }
  });

  it("buys a room once, moves the pet in, and comforts it once a day", async () => {
    const { db, close } = await setup();
    try {
      await refreshPetRoomOffers(db, "owner");
      const room = (await listPetRooms(db, "owner")).offers[0];
      await expectApiError(purchasePetRoom(db, "owner", room.id, async () => {}), "PET_NOT_ENOUGH_GOLD");
      await expectApiError(movePetToRoom(db, "owner", room.id), "PET_ROOM_NOT_FOUND");

      await db.update(userWallets).set({ gold: 500 }).where(eq(userWallets.userId, "owner"));
      const before = (await getPet(db, "owner")).pet!.stats;
      await purchasePetRoom(db, "owner", room.id, async () => {});
      await expectApiError(purchasePetRoom(db, "owner", room.id, async () => {}), "PET_ROOM_OWNED");

      // Reading the pet lands today's comfort from its new room, once.
      const pet = PetResponseV1Schema.parse(await getPet(db, "owner")).pet!;
      expect(pet.room).toEqual({ id: room.id, title: room.title, artKey: room.artKey });
      expect(pet.stats.gold).toBe(500 - room.price);
      expect(pet.stats.energy).toBe(Math.min(100, before.energy + room.effects.energy));
      expect(pet.stats.happiness).toBe(Math.min(100, before.happiness + room.effects.happiness));
      expect((await getPet(db, "owner")).pet!.stats).toEqual(pet.stats);
      const roomLines = (await listPetEvents(db, "owner", { limit: 20 })).events.filter((event) => event.kind === "room");
      expect(roomLines.map((event) => event.title)).toEqual([`A day in ${room.title}`, `Moved into ${room.title}`]);

      const rooms = await listPetRooms(db, "owner");
      expect(rooms.activeRoomId).toBe(room.id);
      expect(rooms.owned.map((owned) => owned.id)).toEqual([room.id]);
      expect(rooms.offers).toHaveLength(ROOM_OFFER_COUNT - 1);

      await movePetToRoom(db, "owner", null);
      expect((await getPet(db, "owner")).pet!.room).toBeNull();
      await movePetToRoom(db, "owner", room.id);
      expect((await getPet(db, "owner")).pet!.room?.id).toBe(room.id);
    } finally {
      await close();
    }
  });
});
