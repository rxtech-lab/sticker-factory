import { getDatabase } from "@/lib/db/client";
import { petRooms, petThemes, userPets } from "@/lib/db/schema";
import { getObjectStore } from "@/lib/storage/r2";

/**
 * Empties every room shop and every pet's places so the next read draws new ones: deletes all rooms
 * (offered and owned) and places with their art, moves pets out and home, and clears the restock
 * and discovery clocks.
 */
const db = await getDatabase();

const removedRooms = await db.delete(petRooms).returning({ userId: petRooms.userId, artKey: petRooms.artKey });
const removedThemes = await db.delete(petThemes).returning({ userId: petThemes.userId, artKey: petThemes.artKey });
await db.update(userPets).set({
  roomId: null, roomEffectDate: null, roomsOfferedAt: null, roomsClaimedAt: null,
  themeId: null, themeUsageJson: null, themesDiscoveredAt: null, themesClaimedAt: null,
});

const store = getObjectStore();
const results = await Promise.allSettled([
  ...removedRooms.map((room) => store.delete(`private/pet-rooms/${room.userId}/${room.artKey}.webp`)),
  ...removedThemes.map((theme) => store.delete(`private/pet-themes/${theme.userId}/${theme.artKey}.webp`)),
]);
const failed = results.filter((result) => result.status === "rejected").length;

console.log(`Removed ${removedRooms.length} rooms and ${removedThemes.length} places (${failed} art deletes failed); `
  + "room shops restock and places are found again on next read.");
process.exit(0);
