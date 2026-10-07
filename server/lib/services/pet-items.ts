import { createHash } from "node:crypto";
import { and, eq, isNull, lt, ne, or, sql, type SQL } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetAction } from "@/lib/ai/gateway-contracts";
import {
  PET_SHOP_FIRST_STOCK_MAX, PET_SHOP_FIRST_STOCK_MIN, PET_SHOP_MAX, PET_SHOP_RESTOCK_MAX, PetActionV1Schema,
} from "@/lib/contracts/api";
import { type Database } from "@/lib/db/client";
import { userPets, type PetBagUnit, type UserPetRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { keepsHours, leavesAt, legacyKeepsHours, liveBag, liveShelf, shopVersion, withEnergyRestorer } from "@/lib/pets/items";
import { petLog, petRandom } from "@/lib/pets/log";
import { localDate } from "@/lib/pets/signals";
import { getObjectStore } from "@/lib/storage/r2";
import { ownerMoment, sentStickerImage } from "./pet-actions";
import { currentStats, petRow, type PetRow } from "./pet-state";
import { lastPublishedPlayback } from "./playback";

const RETRY_AFTER_MS = 10 * 60 * 1000;
const ART_SIZE = 1024;
const CELL_SIZE = ART_SIZE / 2;
const ITEM_SIZE = 256;
export const PET_ITEM_MIN_SIZE = 64;
export const PET_ITEM_MAX_SIZE = 512;

/** The owner's local date: the shop restocks once on each. */
function shopDate(pet: UserPetRow, now: Date): string {
  return localDate(now, pet.contextJson?.timeZone);
}

function contextKey(pet: UserPetRow, now: Date): string {
  const location = ownerMoment(pet.contextJson, now).location;
  return createHash("sha256").update(JSON.stringify({
    version: 3,
    date: shopDate(pet, now),
    location,
    weather: pet.signalsJson?.weather ?? null,
    headlines: pet.signalsJson?.headlines ?? [],
    mood: pet.statusJson?.caption ?? null,
  })).digest("hex");
}

/** Holds a write to the bag the caller read, so two changes racing never lose one another. */
export function bagUnchanged(bag: PetBagUnit[]): SQL {
  return sql`${userPets.bagJson} = ${JSON.stringify(bag)}::jsonb`;
}

function shelfUnchanged(items: PetAction[] | null): SQL {
  return items ? sql`${userPets.itemsJson} = ${JSON.stringify(items)}::jsonb` : isNull(userPets.itemsJson);
}

function isMissingObject(error: unknown): boolean {
  return (error instanceof ApiError && error.status === 404)
    || (error instanceof Error && error.name === "NoSuchKey");
}

/** One item's picture, kept while the item is on the shelf or in the bag. */
function itemArtPath(pet: Pick<UserPetRow, "userId" | "lifeId">, itemId: string): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/items/${itemId}-${ITEM_SIZE}.webp`;
}

// Shops stocked before items left the shelf were four items drawn in one 2×2 sheet, named by
// `itemsArtKey`, with a stored crop per cell. Their items carry no `leavesAt`.
function legacySheetPath(pet: Pick<UserPetRow, "userId" | "lifeId">, key: string, extension: "webp" | "png"): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/${key}.${extension}`;
}

function legacyCropPath(pet: Pick<UserPetRow, "userId" | "lifeId">, key: string, index: number): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/${key}-${index}-${ITEM_SIZE}.webp`;
}

async function legacyItemArt(pet: UserPetRow, key: string, index: number): Promise<Uint8Array> {
  try {
    return (await getObjectStore().get(legacyCropPath(pet, key, index))).bytes;
  } catch (error) {
    if (!isMissingObject(error)) throw error;
  }
  const sheet = await getObjectStore().get(legacySheetPath(pet, key, "webp")).catch((error: unknown) => {
    if (!isMissingObject(error)) throw error;
    return getObjectStore().get(legacySheetPath(pet, key, "png"));
  });
  const metadata = await sharp(sheet.bytes).metadata();
  const width = Math.floor((metadata.width ?? ART_SIZE) / 2);
  const height = Math.floor((metadata.height ?? ART_SIZE) / 2);
  return new Uint8Array(await sharp(sheet.bytes).extract({
    left: (index % 2) * width, top: Math.floor(index / 2) * height, width, height,
  }).resize(ITEM_SIZE, ITEM_SIZE).webp({ lossless: true }).toBuffer());
}

async function deleteLegacySheet(pet: UserPetRow, key: string): Promise<void> {
  const paths = [legacySheetPath(pet, key, "webp"), legacySheetPath(pet, key, "png"),
    ...[0, 1, 2, 3].map((index) => legacyCropPath(pet, key, index))];
  await Promise.all(paths.map((path) => getObjectStore().delete(path).catch(() => undefined)));
}

/** An item's picture: its own, or for an item from an old sheet, its cell of that sheet. */
async function readItemArt(pet: UserPetRow, itemId: string): Promise<Uint8Array> {
  try {
    return (await getObjectStore().get(itemArtPath(pet, itemId))).bytes;
  } catch (error) {
    if (!isMissingObject(error)) throw error;
  }
  const index = pet.itemsJson?.findIndex((item) => item.id === itemId && !item.leavesAt) ?? -1;
  if (index < 0 || !pet.itemsArtKey) throw new ApiError(404, "PET_ITEM_ART_NOT_FOUND", "This item's picture is gone.");
  return legacyItemArt(pet, pet.itemsArtKey, index);
}

/** Gives an item from an old sheet a picture of its own, so it outlives the sheet. */
export async function ensureItemArt(pet: UserPetRow, item: PetAction): Promise<void> {
  if (item.leavesAt) return;
  await getObjectStore().put(itemArtPath(pet, item.id), { bytes: await readItemArt(pet, item.id), contentType: "image/webp" });
}

/**
 * Drops the pictures of `itemIds` that are neither on the shelf nor in the bag any more. Best
 * effort: a leftover picture is harmless.
 */
export async function releaseItemArt(db: Database, userId: string, itemIds: string[]): Promise<void> {
  if (!itemIds.length) return;
  const pet = await petRow(db, userId);
  if (!pet) return;
  const inUse = new Set([...(pet.itemsJson ?? []).map((item) => item.id), ...pet.bagJson.map((unit) => unit.item.id)]);
  await Promise.all(itemIds.filter((id) => !inUse.has(id))
    .map((id) => getObjectStore().delete(itemArtPath(pet, id)).catch(() => undefined)));
}

/** Clears what has left the shelf or expired in the bag from the pet's row, and their pictures. */
async function pruneExpired(db: Database, pet: UserPetRow, shelf: PetAction[], bag: PetBagUnit[]): Promise<void> {
  const removed = await db.update(userPets).set({ itemsJson: shelf, bagJson: bag })
    .where(and(eq(userPets.userId, pet.userId), eq(userPets.lifeId, pet.lifeId!),
      shelfUnchanged(pet.itemsJson), bagUnchanged(pet.bagJson)))
    .returning({ userId: userPets.userId });
  if (!removed.length) return;
  const gone = [...(pet.itemsJson ?? []).filter((item) => !shelf.includes(item)).map((item) => item.id),
    ...pet.bagJson.filter((unit) => !bag.includes(unit)).map((unit) => unit.item.id)];
  petLog("items:expired", { userId: pet.userId, lifeId: pet.lifeId, count: gone.length });
  await releaseItemArt(db, pet.userId, gone);
}

/** The grid `count` new objects are drawn in: one cell for one, otherwise two columns. */
function grid(count: number): { columns: number; rows: number } {
  const columns = count === 1 ? 1 : 2;
  return { columns, rows: Math.ceil(count / columns) };
}

/** Cuts a drawn grid of `count` new objects into square cells, in reading order. */
async function drawnCells(drawn: Uint8Array, count: number): Promise<Buffer[]> {
  const { columns, rows } = grid(count);
  const sheet = await sharp(drawn).resize(CELL_SIZE * columns, CELL_SIZE * rows, { fit: "fill" }).png().toBuffer();
  return Promise.all(Array.from({ length: count }, (_, index) => sharp(sheet).extract({
    left: (index % columns) * CELL_SIZE, top: Math.floor(index / columns) * CELL_SIZE, width: CELL_SIZE, height: CELL_SIZE,
  }).png().toBuffer()));
}

/**
 * Keeps the item shop: once a day, in the owner's time zone, what has left the shelf goes and the
 * agent adds a few new things — how many is its call, three or four on the first day. Each item
 * leaves the shelf at its own time, and keeps for its own time once bought, both chosen by the agent
 * for what it is. Between restocks, anything that has left the shelf or expired in the bag is
 * cleared away.
 *
 * New items are drawn together in one sheet, cut into a picture each, and stored before the shelf
 * that names them is published, so a title never points at a missing picture.
 */
export async function refreshPetItems(db: Database, userId: string, now = new Date()): Promise<void> {
  let pet = await petRow(db, userId);
  if (!pet?.lifeId) return;
  const expired = liveShelf(pet.itemsJson, now).length < (pet.itemsJson?.length ?? 0)
    || liveBag(pet.bagJson, now).length < pet.bagJson.length;
  if (expired) {
    await pruneExpired(db, pet, liveShelf(pet.itemsJson, now), liveBag(pet.bagJson, now));
    pet = await petRow(db, userId);
    if (!pet?.lifeId) return;
  }
  const today = shopDate(pet, now);
  if (pet.itemsArtKey && pet.itemsDate === today) return;
  const shelf = liveShelf(pet.itemsJson, now);
  return restock(db, pet, pet.lifeId, shelf, today, now);
}

async function restock(db: Database, pet: PetRow, lifeId: string, shelf: PetAction[], today: string, now: Date): Promise<void> {
  const { userId } = pet;
  const key = contextKey(pet, now);
  const [claimed] = await db.update(userPets).set({ itemsClaimedAt: now })
    .where(and(eq(userPets.userId, userId), eq(userPets.lifeId, lifeId),
      // A request that read an old row must not claim again after another request publishes.
      or(isNull(userPets.itemsArtKey), isNull(userPets.itemsDate), ne(userPets.itemsDate, today)),
      or(isNull(userPets.itemsClaimedAt), lt(userPets.itemsClaimedAt, new Date(now.getTime() - RETRY_AFTER_MS)))))
    .returning({ userId: userPets.userId });
  if (!claimed) return;
  let fresh: PetAction[] = [];
  try {
    // Items from an old four-item sheet get pictures of their own, and lifetimes, as they stay.
    const legacy = shelf.filter((item) => !item.leavesAt);
    await Promise.all(legacy.map((item) => ensureItemArt(pet, item)));
    const kept = shelf.map((item) => item.leavesAt ? item : {
      ...item, effects: { ...item.effects, gold: item.effects.gold ?? 0 },
      leavesAt: leavesAt(24 + Math.floor(petRandom() * 48), now), keepsHours: legacyKeepsHours(item.kind),
    });
    const room = PET_SHOP_MAX - kept.length;
    if (room > 0) {
      const { sticker, revision } = await lastPublishedPlayback(db, userId, pet.stickerId);
      const style = await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId);
      const generated = await getAiProvider().generatePetItems({
        petTitle: sticker.title,
        controls: revision.playbackJson?.document.configuration?.controls ?? [],
        image: style,
        identity: pet.identityJson,
        signals: pet.signalsJson,
        stats: currentStats(pet),
        mood: pet.statusJson?.caption ?? null,
        previous: pet.itemsJson?.map((item) => item.title) ?? [],
        minCount: Math.min(kept.length ? 1 : PET_SHOP_FIRST_STOCK_MIN, room),
        maxCount: Math.min(kept.length ? PET_SHOP_RESTOCK_MAX : PET_SHOP_FIRST_STOCK_MAX, room),
        keeping: kept,
        ...ownerMoment(pet.contextJson, now),
      });
      fresh = withEnergyRestorer(generated.slice(0, room), kept).map(({ shelfHours, keepsHours: keeps, ...item }) => ({
        ...item, id: crypto.randomUUID(), leavesAt: leavesAt(shelfHours, now), keepsHours: keepsHours(keeps),
      }));
      if (fresh.length) {
        const prompt = [
          `A single transparent contact sheet of ${fresh.length} separate physical object${fresh.length === 1 ? "" : "s"}.`,
          "One object centered in each equal square cell, in reading order:",
          ...fresh.map((item, index) => `${index + 1}. ${item.title}: ${item.description}`),
          "Draw only these objects. Keep them entirely within their cells with generous empty margins.",
          "Match the reference pet's outline, palette, shading and texture. Do not draw the pet.",
          "No words, letters, numbers, borders, ground or background. Leave transparent gaps between cells.",
        ].join(" ");
        const drawn = await getAiProvider().generateStickerImage({
          prompt, references: style ? [{ ...style, label: "pet art style reference" }] : [],
          mode: "generate", sheet: { ...grid(fresh.length), count: fresh.length, independentCells: true },
          keepFrame: true, quality: "high",
        });
        const cells = await drawnCells(drawn.bytes, fresh.length);
        const writes = await Promise.allSettled(cells.map(async (cell, index) => getObjectStore().put(itemArtPath(pet, fresh[index].id), {
          bytes: new Uint8Array(await sharp(cell).resize(ITEM_SIZE, ITEM_SIZE).webp({ lossless: true }).toBuffer()),
          contentType: "image/webp",
        })));
        const failed = writes.find((result) => result.status === "rejected");
        if (failed?.status === "rejected") throw failed.reason;
      }
    }
    const items = PetActionV1Schema.array().max(PET_SHOP_MAX).parse([...kept, ...fresh]);
    const published = await db.update(userPets).set({
      itemsJson: items, itemsArtKey: crypto.randomUUID(), itemsContextKey: key, itemsUpdatedAt: now, itemsDate: today,
      itemsClaimedAt: null,
    }).where(and(eq(userPets.userId, userId), eq(userPets.lifeId, lifeId), eq(userPets.itemsClaimedAt, now)))
      .returning({ userId: userPets.userId });
    if (!published.length) {
      await Promise.all(fresh.map((item) => getObjectStore().delete(itemArtPath(pet, item.id)).catch(() => undefined)));
      return;
    }
    if (legacy.length && pet.itemsArtKey) await deleteLegacySheet(pet, pet.itemsArtKey);
    await releaseItemArt(db, userId, (pet.itemsJson ?? []).map((item) => item.id).filter((id) => !items.some((item) => item.id === id)));
    petLog("items:restocked", { userId, lifeId, date: today, kept: kept.map((item) => item.title),
      added: fresh.map((item) => ({ title: item.title, leavesAt: item.leavesAt, keepsHours: item.keepsHours })) });
  } catch (error) {
    await Promise.all(fresh.map((item) => getObjectStore().delete(itemArtPath(pet, item.id)).catch(() => undefined)));
    petLog("items:refresh-failed", { userId, error: describeError(error) });
    // Keep the last shelf; another request may retry after the claim cools down.
  }
}

async function servedArt(pet: UserPetRow, itemId: string, size: number, ifNoneMatch?: string | null) {
  const etag = `"item-${itemId}-${size}-webp-v2"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  const stored = await readItemArt(pet, itemId);
  if (size === ITEM_SIZE) return { etag, bytes: stored };
  return { etag, bytes: new Uint8Array(await sharp(stored).resize(size, size).webp({ lossless: true }).toBuffer()) };
}

/** Serves the picture of an item on the shelf or in the bag. */
export async function getPetItemArtById(
  db: Database, userId: string, itemId: string, size: number, ifNoneMatch?: string | null, now = new Date(),
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const known = liveShelf(pet.itemsJson, now).some((item) => item.id === itemId)
    || liveBag(pet.bagJson, now).some((unit) => unit.item.id === itemId);
  if (!known) throw new ApiError(404, "PET_ITEM_NOT_FOUND", "This item isn't in the shop or your pet's bag.");
  return servedArt(pet, itemId, size, ifNoneMatch);
}

/**
 * Serves the picture of the shelf's `index`th item, for apps that fetch by position. `expectedArtKey`
 * is the shelf they saw; a shelf that has changed since is refused, so a position never shows
 * another item's picture.
 */
export async function getPetItemArt(
  db: Database, userId: string, index: number, size: number, ifNoneMatch?: string | null,
  expectedArtKey?: string | null, now = new Date(),
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  await lastPublishedPlayback(db, userId, pet.stickerId);
  if (!pet.itemsArtKey) throw new ApiError(404, "PET_ITEMS_NOT_READY", "Your pet's items are still being drawn.");
  const shelf = liveShelf(pet.itemsJson, now);
  if (expectedArtKey && expectedArtKey !== shopVersion(shelf)) {
    throw new ApiError(409, "PET_ITEMS_CHANGED", "Your pet's shop has changed. Refresh to see it.");
  }
  const item = shelf[index];
  if (!item) throw new ApiError(404, "PET_ITEM_NOT_FOUND", "This item isn't in the shop.");
  return servedArt(pet, item.id, size, ifNoneMatch);
}
