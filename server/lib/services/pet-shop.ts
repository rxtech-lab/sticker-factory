import { lt, sql } from "drizzle-orm";
import { PET_MEDICINE_PRICE, PET_STOCK_MAX, type PurchasePetItemRequest } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { expiresAt, liveBag, liveShelf } from "@/lib/pets/items";
import { petLog } from "@/lib/pets/log";
import { bagUnchanged, ensureItemArt, releaseItemArt } from "./pet-items";
import { commitPetChange, petRow } from "./pet-state";

type Notify = (db: Database, userId: string) => Promise<void>;

/**
 * Buys a dose of medicine from the item shop, which always has some. It goes on the shelf with the
 * rest of the pet's medicine whether or not the pet is ill; giving it is a separate step.
 */
export async function buyPetMedicine(db: Database, userId: string, notify: Notify = notifyPetStatusChanged): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  if (pet.medicine >= PET_STOCK_MAX) {
    throw new ApiError(422, "PET_STOCK_FULL", `Your pet already has ${PET_STOCK_MAX} doses of medicine.`);
  }
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId,
    price: PET_MEDICINE_PRICE,
    where: lt(userPets.medicine, PET_STOCK_MAX),
    set: { medicine: sql`${userPets.medicine} + 1` },
    changes: [{ kind: "purchase", title: "Bought medicine",
      detail: pet.illnessJson ? `A dose for ${pet.illnessJson.name}.` : "A dose kept for when it's needed.",
      effects: { happiness: 0, hp: 0, energy: 0, gold: -PET_MEDICINE_PRICE }, debug: { medicineBefore: pet.medicine } }],
  });
  if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  petLog("shop:medicine-bought", { userId, lifeId: pet.lifeId, medicine: pet.medicine + 1 });
  await notify(db, userId).catch((error) => petLog("shop:notify-failed", { userId, error: describeError(error) }));
}

/**
 * Buys one of the shop's items into the bag, to use later. It is kept as it was sold, with its
 * picture, so it stays usable after it leaves the shelf — until it expires, as long after buying as
 * the item keeps, or never for things that never expire. Anything in the bag that has expired is
 * cleared away in the same write.
 */
export async function buyPetItem(
  db: Database,
  userId: string,
  input: PurchasePetItemRequest,
  notify: Notify = notifyPetStatusChanged,
  now = new Date(),
): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const shelved = liveShelf(pet.itemsJson, now).find((item) => item.id === input.itemId);
  if (!shelved) throw new ApiError(422, "PET_ITEM_NOT_AVAILABLE", "This item is no longer in the shop.");
  const price = -Math.min(0, shelved.effects.gold ?? 0);
  const live = liveBag(pet.bagJson, now);
  const owned = live.filter((unit) => unit.item.id === shelved.id).length;
  if (owned >= PET_STOCK_MAX) {
    throw new ApiError(422, "PET_STOCK_FULL", `Your pet's bag holds at most ${PET_STOCK_MAX} of each thing.`);
  }
  await ensureItemArt(pet, shelved);
  // The shelf's own clock means nothing once it is in the bag.
  const item = { ...shelved, effects: { ...shelved.effects, gold: shelved.effects.gold ?? 0 }, leavesAt: undefined };
  const unit = { id: crypto.randomUUID(), item, boughtAt: now.toISOString(), expiresAt: expiresAt(item, now) };
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId,
    price,
    where: bagUnchanged(pet.bagJson),
    set: { bagJson: [...live, unit] },
    changes: [{ kind: "purchase", title: `Bought ${item.title}`,
      detail: unit.expiresAt ? `Put ${item.title} in the bag; it keeps for ${item.keepsHours} hours.` : `Put ${item.title} in the bag for later.`,
      effects: { happiness: 0, hp: 0, energy: 0, gold: -price },
      debug: { itemId: item.id, kind: item.kind, ownedBefore: owned, expiresAt: unit.expiresAt } }],
  });
  if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  await releaseItemArt(db, userId, pet.bagJson.filter((candidate) => !live.includes(candidate)).map((candidate) => candidate.item.id));
  petLog("shop:item-bought", { userId, lifeId: pet.lifeId, itemId: item.id, title: item.title, owned: owned + 1, expiresAt: unit.expiresAt });
  await notify(db, userId).catch((error) => petLog("shop:notify-failed", { userId, error: describeError(error) }));
}
