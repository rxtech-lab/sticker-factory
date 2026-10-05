import { createHash } from "node:crypto";
import { and, eq, isNull, lt, lte, or } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider } from "@/lib/ai/gateway";
import { PetActionV1Schema } from "@/lib/contracts/api";
import { type Database } from "@/lib/db/client";
import { userPets, type UserPetRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { withEnergyRestorer } from "@/lib/pets/items";
import { petLog } from "@/lib/pets/log";
import { getObjectStore } from "@/lib/storage/r2";
import { ownerMoment, sentStickerImage } from "./pet-actions";
import { currentStats, petRow } from "./pet-state";
import { readablePlayback } from "./playback";

const RETRY_AFTER_MS = 10 * 60 * 1000;
const REFRESH_EVERY_MS = 12 * 60 * 60 * 1000;
const ART_SIZE = 1024;
const ITEM_SIZE = 256;
export const PET_ITEM_MIN_SIZE = 64;
export const PET_ITEM_MAX_SIZE = 512;

function contextKey(pet: UserPetRow, now: Date): string {
  const location = ownerMoment(pet.contextJson, now).location;
  return createHash("sha256").update(JSON.stringify({
    version: 1,
    period: Math.floor(now.getTime() / REFRESH_EVERY_MS),
    location,
    weather: pet.signalsJson?.weather ?? null,
    headlines: pet.signalsJson?.headlines ?? [],
    mood: pet.statusJson?.caption ?? null,
  })).digest("hex");
}

function artPath(pet: Pick<UserPetRow, "userId" | "lifeId">, key: string): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/${key}.webp`;
}

function legacyArtPath(pet: Pick<UserPetRow, "userId" | "lifeId">, key: string): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/${key}.png`;
}

function isMissingObject(error: unknown): boolean {
  return (error instanceof ApiError && error.status === 404)
    || (error instanceof Error && error.name === "NoSuchKey");
}

function itemPath(pet: Pick<UserPetRow, "userId" | "lifeId">, key: string, index: number): string {
  return `private/pet-items/${pet.userId}/${pet.lifeId}/${key}-${index}-${ITEM_SIZE}.webp`;
}

async function deleteArt(pet: UserPetRow, key: string): Promise<void> {
  const paths = [artPath(pet, key), legacyArtPath(pet, key), ...[0, 1, 2, 3].map((index) => itemPath(pet, key, index))];
  await Promise.all(paths.map((path) => getObjectStore().delete(path).catch(() => undefined)));
}

async function cropItem(sheet: Uint8Array, index: number, size: number): Promise<Uint8Array> {
  const metadata = await sharp(sheet).metadata();
  const halfWidth = Math.floor((metadata.width ?? ART_SIZE) / 2);
  const halfHeight = Math.floor((metadata.height ?? ART_SIZE) / 2);
  return new Uint8Array(await sharp(sheet).extract({
    left: (index % 2) * halfWidth, top: Math.floor(index / 2) * halfHeight,
    width: halfWidth, height: halfHeight,
  }).resize(size, size).webp({ lossless: true }).toBuffer());
}

/** Four choices and one sheet are published together, so a title never points at the wrong crop. */
export async function refreshPetItems(db: Database, userId: string, now = new Date()): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) return;
  const expiredAt = new Date(now.getTime() - REFRESH_EVERY_MS);
  // Keep a complete set for twelve hours from its stored timestamp, even when mood or weather changes.
  if (pet.itemsArtKey && pet.itemsJson?.length === 4 && pet.itemsUpdatedAt && pet.itemsUpdatedAt > expiredAt) return;
  const key = contextKey(pet, now);
  const [claimed] = await db.update(userPets).set({ itemsClaimedAt: now })
    .where(and(eq(userPets.userId, userId), eq(userPets.lifeId, pet.lifeId),
      // A request that read an old row must not claim again after another request publishes.
      or(isNull(userPets.itemsArtKey), isNull(userPets.itemsJson),
        isNull(userPets.itemsUpdatedAt), lte(userPets.itemsUpdatedAt, expiredAt)),
      or(isNull(userPets.itemsClaimedAt), lt(userPets.itemsClaimedAt, new Date(now.getTime() - RETRY_AFTER_MS)))))
    .returning({ userId: userPets.userId });
  if (!claimed) return;
  let pendingArtKey: string | undefined;
  try {
    const { sticker, revision } = await readablePlayback(db, userId, pet.stickerId);
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
      ...ownerMoment(pet.contextJson, now),
    });
    const items = PetActionV1Schema.array().length(4).parse(
      withEnergyRestorer(generated).map((item) => ({ ...item, id: crypto.randomUUID() })),
    );
    const prompt = [
      "A single transparent 2 by 2 contact sheet of four separate physical objects.",
      "One object centered in each equal square cell, in reading order:",
      ...items.map((item, index) => `${index + 1}. ${item.title}: ${item.description}`),
      "Draw only these objects. Keep them entirely within their cells with generous empty margins.",
      "Match the reference pet's outline, palette, shading and texture. Do not draw the pet.",
      "No words, letters, numbers, borders, ground or background. Leave transparent gaps between cells.",
    ].join(" ");
    const drawn = await getAiProvider().generateStickerImage({
      prompt, references: style ? [{ ...style, label: "pet art style reference" }] : [],
      mode: "generate", sheet: { columns: 2, rows: 2, count: 4, independentCells: true },
      keepFrame: true, quality: "high",
    });
    // Normalize the sheet to an even square frame; every crop then has the same stable bounds.
    const bytes = await sharp(drawn.bytes).resize(ART_SIZE, ART_SIZE, {
      fit: "fill",
    }).webp({ lossless: true }).toBuffer();
    const artKey = crypto.randomUUID();
    pendingArtKey = artKey;
    // Store the app's four thumbnails once, before publishing their artwork version.
    const crops = await Promise.all(items.map((_, index) => cropItem(bytes, index, ITEM_SIZE)));
    const writes = await Promise.allSettled([
      getObjectStore().put(artPath(pet, artKey), { bytes: new Uint8Array(bytes), contentType: "image/webp" }),
      ...crops.map((crop, index) => getObjectStore().put(itemPath(pet, artKey, index), {
        bytes: crop, contentType: "image/webp",
      })),
    ]);
    const failed = writes.find((result) => result.status === "rejected");
    if (failed?.status === "rejected") throw failed.reason;
    const published = await db.update(userPets).set({
      itemsJson: items, itemsArtKey: artKey, itemsContextKey: key, itemsUpdatedAt: now,
      itemsClaimedAt: null,
    }).where(and(eq(userPets.userId, userId), eq(userPets.lifeId, pet.lifeId), eq(userPets.itemsClaimedAt, now)))
      .returning({ userId: userPets.userId });
    if (!published.length) {
      await deleteArt(pet, artKey);
      return;
    }
    pendingArtKey = undefined;
    if (pet.itemsArtKey) await deleteArt(pet, pet.itemsArtKey);
    petLog("items:refreshed", { userId, lifeId: pet.lifeId, count: items.length });
  } catch (error) {
    if (pendingArtKey) await deleteArt(pet, pendingArtKey);
    petLog("items:refresh-failed", { userId, error: describeError(error) });
    // Keep the last complete set; another request may retry after the claim cools down.
  }
}

/** Serves one quadrant of the single generated sheet for the current pet. */
export async function getPetItemArt(
  db: Database, userId: string, index: number, size: number, ifNoneMatch?: string | null,
  expectedArtKey?: string | null,
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  await readablePlayback(db, userId, pet.stickerId);
  if (!pet.itemsArtKey || pet.itemsJson?.length !== 4) {
    throw new ApiError(404, "PET_ITEMS_NOT_READY", "Your pet's items are still being drawn.");
  }
  if (expectedArtKey && expectedArtKey !== pet.itemsArtKey) {
    throw new ApiError(409, "PET_ITEMS_CHANGED", "Your pet has chosen new items. Refresh to see them.");
  }
  const etag = `"${pet.itemsArtKey}-${index}-${size}-webp-v1"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  if (size === ITEM_SIZE) {
    try {
      const cached = await getObjectStore().get(itemPath(pet, pet.itemsArtKey, index));
      return { etag, bytes: cached.bytes };
    } catch (error) {
      if (!isMissingObject(error)) throw error;
    }
  }
  // Legacy PNG sheets remain readable until their normal twelve-hour refresh.
  const sheet = await getObjectStore().get(artPath(pet, pet.itemsArtKey)).catch((error: unknown) => {
    if (!isMissingObject(error)) throw error;
    return getObjectStore().get(legacyArtPath(pet, pet.itemsArtKey!));
  });
  return { etag, bytes: await cropItem(sheet.bytes, index, size) };
}
