import { and, asc, desc, eq, isNull, lt, lte, or } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetRoomsV1, PetRoomV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petRooms, userPets, type PetRoomRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { renderRoomArt, roomWindowKey } from "@/lib/pets/room-art";
import { describeRoomEffects, ROOM_OFFER_LIFETIME_MS, sanitizeRoom } from "@/lib/pets/rooms";
import { getObjectStore } from "@/lib/storage/r2";
import { ownerMoment, sentStickerImage } from "./pet-actions";
import { commitPetChange, currentStats, petRow, type PetRow } from "./pet-state";
import { readablePlayback } from "./playback";

/** A refresh that has not published within this long is taken to have died, and may be tried again. */
const RETRY_AFTER_MS = 10 * 60 * 1000;

function artPath(userId: string, artKey: string): string {
  return `private/pet-rooms/${userId}/${artKey}.webp`;
}

async function deleteArt(userId: string, artKeys: string[]): Promise<void> {
  await Promise.all(artKeys.map((key) => getObjectStore().delete(artPath(userId, key)).catch(() => undefined)));
}

function serializeRoom(row: PetRoomRow): PetRoomV1 {
  return {
    id: row.id, title: row.title, description: row.description, effects: row.effectsJson,
    price: row.price, artKey: row.artKey, owned: row.state === "owned",
  };
}

/** The room the pet lives in, as `GET /api/v1/pet` names it. */
export function serializePetRoom(row: Pick<PetRow, "room">): { id: string; title: string; artKey: string } | null {
  return row.room ? { id: row.room.id, title: row.room.title, artKey: row.room.artKey } : null;
}

/** The owner's rooms, the shop's offers, and which room the pet lives in. */
export async function listPetRooms(db: Database, userId: string, now = new Date()): Promise<PetRoomsV1> {
  const pet = await petRow(db, userId);
  const rows = await db.select().from(petRooms).where(eq(petRooms.userId, userId))
    .orderBy(asc(petRooms.price), asc(petRooms.createdAt));
  const offeredAt = pet?.roomsOfferedAt ?? null;
  return {
    activeRoomId: pet?.room?.id ?? null,
    owned: rows.filter((row) => row.state === "owned")
      .sort((a, b) => (b.purchasedAt?.getTime() ?? 0) - (a.purchasedAt?.getTime() ?? 0))
      .map(serializeRoom),
    offers: rows.filter((row) => row.state === "offered").map(serializeRoom),
    offersRefreshAt: offeredAt ? new Date(offeredAt.getTime() + ROOM_OFFER_LIFETIME_MS).toISOString() : null,
    // Every read of a shop that is due restocks it, so a due shop is one being drawn.
    drawing: !!pet?.lifeId && (!offeredAt || offeredAt.getTime() <= now.getTime() - ROOM_OFFER_LIFETIME_MS),
  };
}

/**
 * Puts new rooms in the pet's shop once the last ones have been up a day: the agent designs them
 * for this pet and its world, and each is drawn in the pet's style. The old offers nobody bought go.
 *
 * Claimed first, so two reads draw them once. Never throws: a shop that could not restock keeps
 * what it has, and the next read after the claim cools down tries again.
 */
export async function refreshPetRoomOffers(db: Database, userId: string, now = new Date()): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) return;
  const staleBefore = new Date(now.getTime() - ROOM_OFFER_LIFETIME_MS);
  if (pet.roomsOfferedAt && pet.roomsOfferedAt > staleBefore) return;
  const [claimed] = await db.update(userPets).set({ roomsClaimedAt: now })
    .where(and(eq(userPets.userId, userId),
      // A request that read the row before another one restocked must not claim it again.
      or(isNull(userPets.roomsOfferedAt), lte(userPets.roomsOfferedAt, staleBefore)),
      or(isNull(userPets.roomsClaimedAt), lt(userPets.roomsClaimedAt, new Date(now.getTime() - RETRY_AFTER_MS)))))
    .returning({ userId: userPets.userId });
  if (!claimed) return;
  const drawn: string[] = [];
  try {
    const { sticker, revision } = await readablePlayback(db, userId, pet.stickerId);
    const style = await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId);
    const earlier = await db.select({ title: petRooms.title }).from(petRooms)
      .where(eq(petRooms.userId, userId)).orderBy(desc(petRooms.createdAt)).limit(24);
    const designed = (await getAiProvider().generatePetRooms({
      petTitle: sticker.title,
      controls: revision.playbackJson?.document.configuration?.controls ?? [],
      image: style,
      identity: pet.identityJson,
      signals: pet.signalsJson,
      stats: currentStats(pet),
      mood: pet.statusJson?.caption ?? null,
      previous: earlier.map((room) => room.title),
      ...ownerMoment(pet.contextJson, now),
    })).map(sanitizeRoom);
    // Drawn side by side; a room that could not be drawn is left out rather than shown blank.
    const rooms = (await Promise.all(designed.map(async (room) => {
      try {
        const windowKey = roomWindowKey(room.scene);
        const art = await getAiProvider().generatePetRoomArt({ scene: room.scene, reference: style, windowKey });
        // Its windows become see-through, so the app can show the owner's weather behind the glass.
        const { bytes, windowFraction } = await renderRoomArt(art.bytes, windowKey);
        if (!windowFraction) petLog("rooms:no-window", { userId, title: room.title, key: windowKey.name });
        const artKey = crypto.randomUUID();
        await getObjectStore().put(artPath(userId, artKey), { bytes, contentType: "image/webp" });
        drawn.push(artKey);
        return { ...room, artKey };
      } catch (error) {
        petLog("rooms:draw-failed", { userId, title: room.title, error: describeError(error) });
        return null;
      }
    }))).filter((room) => room !== null);
    if (!rooms.length) throw new Error("No room could be drawn");

    const stale = await db.transaction(async (tx) => {
      const published = await tx.update(userPets).set({ roomsOfferedAt: now, roomsClaimedAt: null })
        .where(and(eq(userPets.userId, userId), eq(userPets.roomsClaimedAt, now)))
        .returning({ userId: userPets.userId });
      if (!published.length) return null;
      const removed = await tx.delete(petRooms)
        .where(and(eq(petRooms.userId, userId), eq(petRooms.state, "offered")))
        .returning({ artKey: petRooms.artKey });
      await tx.insert(petRooms).values(rooms.map((room) => ({
        id: crypto.randomUUID(), userId, title: room.title.slice(0, 32), description: room.description.slice(0, 140),
        effectsJson: room.effects, price: room.price, artKey: room.artKey, state: "offered" as const, createdAt: now,
      })));
      return removed.map((row) => row.artKey);
    });
    if (!stale) {
      await deleteArt(userId, drawn);
      return;
    }
    await deleteArt(userId, stale);
    petLog("rooms:offered", { userId, lifeId: pet.lifeId,
      rooms: rooms.map((room) => ({ title: room.title, price: room.price, effects: room.effects })) });
  } catch (error) {
    await deleteArt(userId, drawn);
    // The claim is kept: the next read tries again once it cools down, not on every poll.
    petLog("rooms:refresh-failed", { userId, error: describeError(error) });
  }
}

/**
 * Buys a room from the shop and moves the pet into it. The room is claimed before the gold moves,
 * so a double tap buys it once; a purchase that cannot be paid for puts it back on the shelf.
 */
export async function purchasePetRoom(
  db: Database,
  userId: string,
  roomId: string,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const room = await db.select().from(petRooms)
    .where(and(eq(petRooms.id, roomId), eq(petRooms.userId, userId))).then(firstRow);
  if (!room) throw new ApiError(404, "PET_ROOM_NOT_FOUND", "This room is no longer for sale.");
  if (room.state === "owned") throw new ApiError(409, "PET_ROOM_OWNED", "You already have this room.");
  const gold = currentStats(pet).gold;
  if (room.price > gold) {
    throw new ApiError(422, "PET_NOT_ENOUGH_GOLD", `This room costs ${room.price} gold, and you have ${gold}.`);
  }
  const now = new Date();
  const [claimed] = await db.update(petRooms).set({ state: "owned", purchasedAt: now })
    .where(and(eq(petRooms.id, room.id), eq(petRooms.state, "offered")))
    .returning({ id: petRooms.id });
  if (!claimed) throw new ApiError(409, "PET_ROOM_OWNED", "You already have this room.");
  let committed;
  try {
    committed = await commitPetChange(db, userId, {
      lifeId: pet.lifeId,
      price: room.price,
      set: { roomId: room.id },
      changes: [{
        kind: "room",
        title: `Moved into ${room.title}`,
        detail: `Bought ${room.title} for ${room.price} gold. Each day there: ${describeRoomEffects(room.effectsJson)}.`,
        effects: { happiness: 0, hp: 0, energy: 0, gold: -room.price },
        debug: { source: "room-purchase", roomId: room.id, price: room.price, effects: room.effectsJson,
          previousRoomId: pet.roomId },
      }],
    });
  } catch (error) {
    await unclaim(db, room.id);
    throw error;
  }
  if (!committed) {
    await unclaim(db, room.id);
    throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  }
  petLog("rooms:purchased", { userId, lifeId: pet.lifeId, roomId: room.id, title: room.title, price: room.price });
  await notify(db, userId).catch((error) => petLog("rooms:notify-failed", { userId, error: describeError(error) }));
}

async function unclaim(db: Database, roomId: string): Promise<void> {
  await db.update(petRooms).set({ state: "offered", purchasedAt: null }).where(eq(petRooms.id, roomId));
}

/** Moves the pet into a room the owner has, or back onto the plain page with null. Free, any time. */
export async function movePetToRoom(db: Database, userId: string, roomId: string | null): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  if (roomId) {
    const owned = await db.select({ id: petRooms.id }).from(petRooms)
      .where(and(eq(petRooms.id, roomId), eq(petRooms.userId, userId), eq(petRooms.state, "owned"))).then(firstRow);
    if (!owned) throw new ApiError(404, "PET_ROOM_NOT_FOUND", "Buy this room before moving your pet in.");
  }
  await db.update(userPets).set({ roomId }).where(eq(userPets.userId, userId));
  petLog("rooms:moved", { userId, lifeId: pet.lifeId, from: pet.roomId, to: roomId });
}

/** One room's drawing, owned or on offer, for the owner who can see it. */
export async function getPetRoomArt(
  db: Database, userId: string, roomId: string, ifNoneMatch?: string | null,
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const room = await db.select({ artKey: petRooms.artKey }).from(petRooms)
    .where(and(eq(petRooms.id, roomId), eq(petRooms.userId, userId)))
    .then(firstRow);
  if (!room) throw new ApiError(404, "PET_ROOM_NOT_FOUND", "This room is no longer for sale.");
  const etag = `"${room.artKey}-webp-v1"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  const art = await getObjectStore().get(artPath(userId, room.artKey));
  return { etag, bytes: art.bytes };
}
