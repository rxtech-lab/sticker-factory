// The weather where the owner is, drawn in the pet's own art style: a sun, a rain cloud, a moon,
// looking like it came off the same sheet as the pet. The Pet tab stands it behind the pet and
// animates it; the widget shows it beside the pet.
//
// Drawn once per look — the pet's sticker, the kind of weather, day or night — and kept, so a rainy
// Tuesday costs nothing if it already rained on Monday. Each look belongs to the sticker's current
// playback revision; updating the sticker invalidates it. Drawing happens after a response is out; until it lands the
// client shows the weather as a symbol.
//
// A pet living in a room with windows also gets the weather outside them: a 2×2 sheet of sky pieces
// in the same style — the sun or moon, a wide cloud, a small cloud and one falling particle — that the
// app moves live behind the window glass. Until that lands the app paints the sky itself.

import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetSignalsV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petWeatherArt, type PetWeatherArtLayer, type PetWeatherArtRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { getObjectStore } from "@/lib/storage/r2";
import { sentStickerImage } from "./pet-actions";
import { petRow } from "./pet-state";
import { readablePlayback } from "./playback";

type Weather = NonNullable<PetSignalsV1["weather"]>;

/** Edges the weather may be drawn at: a widget's corner up to the Pet tab at 3x. */
export const PET_WEATHER_ART_MIN_SIZE = 64;
export const PET_WEATHER_ART_MAX_SIZE = 512;
/** The window sheet is four pieces, so it may be fetched at twice the edge. */
export const PET_WINDOW_WEATHER_ART_MAX_SIZE = 1024;
/** Each of the window sheet's four cells, stored at this edge with its piece fitted inside. */
const WINDOW_CELL_SIZE = 512;
/** Room each piece keeps from its cell's edge, so a resize never bleeds one piece into the next. */
const WINDOW_CELL_MARGIN = 16;

/** A claim older than this belongs to a draw that died; the next read may draw it again. */
const DRAWING_STALE_MS = 10 * 60 * 1000;
/** A look the model failed to draw is not asked for again for this long. */
const FAILED_RETRY_MS = 6 * 60 * 60 * 1000;

/** What each weather looks like, as the image model is asked for it. */
const LOOKS: Record<Weather["kind"], { day: string; night: string }> = {
  sunny: {
    day: "a cheerful round sun with short chunky rays",
    night: "a sleepy crescent moon with two or three small twinkling stars",
  },
  cloudy: {
    day: "two soft, puffy overlapping clouds",
    night: "two soft, puffy clouds with a small crescent moon peeking from behind them",
  },
  rainy: {
    day: "one puffy rain cloud with a few fat raindrops falling from it",
    night: "one dusky blue rain cloud with a few fat raindrops falling from it",
  },
  snowy: {
    day: "one soft snow cloud with a few big, simple snowflakes drifting down",
    night: "one dusky snow cloud with a few big, simple snowflakes drifting down",
  },
  stormy: {
    day: "one dark, grumpy storm cloud with a zig-zag lightning bolt and a few raindrops",
    night: "one dark, grumpy night storm cloud with a bright zig-zag lightning bolt",
  },
  foggy: {
    day: "three soft, wavy bands of mist stacked loosely",
    night: "three soft, wavy bands of bluish night mist stacked loosely",
  },
  windy: {
    day: "two or three curling gusts of wind with a couple of leaves tumbling in them",
    night: "two or three curling gusts of night wind with a couple of leaves tumbling in them",
  },
};

/**
 * The four pieces of the sky outside a window, in the cells the app reads them from: the sky's body
 * (left alone, pulsing or flashing), a wide cloud and a small cloud (drifting), and one particle the
 * app repeats many times (falling, tumbling or twinkling).
 */
const WINDOW_LOOKS: Record<Weather["kind"], { day: WindowPieces; night: WindowPieces }> = {
  sunny: {
    day: ["a big round sun with short chunky rays", "a wide, flat, fluffy fair-weather cloud",
      "a small round puffy cloud", "one small bird in flight seen from the side, wings raised"],
    night: ["a glowing crescent moon", "a long thin wisp of pale night cloud",
      "a small wisp of pale night cloud", "one small four-pointed twinkling star"],
  },
  cloudy: {
    day: ["a soft pale sun with no rays", "a big wide heavy white-grey cumulus cloud",
      "a medium puffy white-grey cloud", "a tiny round puff of cloud"],
    night: ["a faint pale crescent moon", "a big wide dusky blue cloud",
      "a medium puffy dusky blue cloud", "a tiny round puff of dusky cloud"],
  },
  rainy: {
    day: ["a very wide, heavy grey rain cloud with a flat underside", "a medium grey rain cloud",
      "a small grey cloud", "one single fat teardrop-shaped raindrop"],
    night: ["a very wide, heavy dusky blue rain cloud with a flat underside", "a medium dusky blue rain cloud",
      "a small dusky blue cloud", "one single fat teardrop-shaped raindrop"],
  },
  snowy: {
    day: ["a very wide, soft pale snow cloud with a flat underside", "a medium soft snow cloud",
      "a small soft snow cloud", "one single big simple six-pointed snowflake"],
    night: ["a very wide, soft dusky snow cloud with a flat underside", "a medium dusky snow cloud",
      "a small dusky snow cloud", "one single big simple six-pointed snowflake"],
  },
  stormy: {
    day: ["one tall bright yellow zig-zag lightning bolt", "a huge, wide, dark grumpy storm cloud",
      "a medium dark storm cloud", "one single slanted raindrop"],
    night: ["one tall bright yellow zig-zag lightning bolt", "a huge, wide, very dark night storm cloud",
      "a medium very dark night storm cloud", "one single slanted raindrop"],
  },
  foggy: {
    day: ["a pale hazy sun disc with no rays", "a long, low, wavy band of white mist",
      "a shorter wavy band of white mist", "one small soft curl of mist"],
    night: ["a pale hazy moon disc", "a long, low, wavy band of bluish night mist",
      "a shorter wavy band of bluish night mist", "one small soft curl of bluish mist"],
  },
  windy: {
    day: ["a round sun with short chunky rays", "a long cloud stretched thin by the wind",
      "one curling swirl of wind drawn as a line", "one single green leaf"],
    night: ["a glowing crescent moon", "a long night cloud stretched thin by the wind",
      "one curling swirl of night wind drawn as a line", "one single dark green leaf"],
  },
};
type WindowPieces = [body: string, wideCloud: string, smallCloud: string, particle: string];

function windowPrompt(weather: Pick<Weather, "kind" | "isDay">): string {
  const pieces = WINDOW_LOOKS[weather.kind][weather.isDay ? "day" : "night"];
  return [
    "A single transparent 2 by 2 contact sheet of four separate weather elements for an animated sky.",
    "One element centred in each equal square cell, in reading order:",
    ...pieces.map((piece, index) => `${index + 1}. ${piece}.`),
    "Draw each element whole and on its own, entirely within its cell with generous empty margins.",
    "Draw them in exactly the art style of the reference character — the same outline weight and colour,",
    "palette, shading, texture and level of detail — so they look like they belong on the same sticker sheet.",
    "Do not draw the character itself or any part of it, and no faces.",
    "No words, letters, numbers, borders, ground, sky colour or background. Leave transparent gaps between cells.",
  ].join(" ");
}

function drawingPrompt(weather: Pick<Weather, "kind" | "isDay">): string {
  const look = LOOKS[weather.kind][weather.isDay ? "day" : "night"];
  return [
    `A single small weather sticker: ${look}.`,
    "Draw it in exactly the art style of the reference character — the same outline weight and colour,",
    "palette, shading, texture and level of detail — so it looks like it belongs on the same sticker sheet.",
    "Do not draw the character itself or any part of it. Give the weather a simple face only if the character",
    "is drawn as a cute cartoon. No text, no ground, no sky, no frame, no background: only the weather element,",
    "centred, on a transparent background.",
  ].join(" ");
}

/** Names exactly what a ready row shows, so a client re-fetches only when the drawing changed. */
function artKey(row: PetWeatherArtRow): string {
  return createHash("sha256").update(`${row.id}:${row.revisionId}:${row.readyAt?.toISOString() ?? ""}`).digest("hex").slice(0, 24);
}

async function lookRow(db: Database, stickerId: string, weather: Pick<Weather, "kind" | "isDay">, layer: PetWeatherArtLayer) {
  return db.select().from(petWeatherArt)
    .where(and(eq(petWeatherArt.stickerId, stickerId), eq(petWeatherArt.kind, weather.kind),
      eq(petWeatherArt.isDay, weather.isDay), eq(petWeatherArt.layer, layer)))
    .then(firstRow);
}

/**
 * `PetResponseV1.pet.weatherArt` (`sticker`) and `.windowWeatherArt` (`window`): the drawn look for
 * the weather now, or null until it is drawn.
 */
export async function serializePetWeatherArt(
  db: Database, stickerId: string, signals: PetSignalsV1 | null, revisionId: string, layer: PetWeatherArtLayer = "sticker",
) {
  const weather = signals?.weather;
  if (!weather) return null;
  const row = await lookRow(db, stickerId, weather, layer);
  if (row?.state !== "ready" || !row.r2Key || row.revisionId !== revisionId) return null;
  return { kind: weather.kind, isDay: weather.isDay, key: artKey(row) };
}

/**
 * Draws the weather the caller's pet is in now, unless that look is already drawn or being drawn —
 * and, while the pet lives in a room, the sky outside its window too.
 *
 * Runs after a response, so it never throws: a pet without its weather drawn still has the symbol.
 */
export async function drawPetWeatherArt(db: Database, userId: string, now = new Date()): Promise<void> {
  const pet = await petRow(db, userId).catch(() => undefined);
  await Promise.all([
    drawLook(db, userId, "sticker", now),
    // Only a pet in a room has a window to look out of; the sky waits until it moves in.
    pet?.roomId ? drawLook(db, userId, "window", now) : undefined,
  ]);
}

/** Draws one layer of the weather now. Never throws. */
async function drawLook(db: Database, userId: string, layer: PetWeatherArtLayer, now: Date): Promise<void> {
  let claimed: PetWeatherArtRow | undefined;
  try {
    const pet = await petRow(db, userId);
    const weather = pet?.signalsJson?.weather;
    if (!pet || !weather) return;
    const { revision } = await readablePlayback(db, userId, pet.stickerId);
    claimed = await claimLook(db, pet.stickerId, revision.id, weather, layer, now);
    if (!claimed) return;
    const style = await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId);
    const references = style ? [{ ...style, label: "the pet character, for its art style only" }] : [];
    const bytes = layer === "window"
      ? await windowSheet((await getAiProvider().generateStickerImage({
        prompt: windowPrompt(weather), references, mode: "generate",
        sheet: { columns: 2, rows: 2, count: 4, independentCells: true }, keepFrame: true, quality: "high",
      })).bytes)
      : (await getAiProvider().generateStickerImage({
        prompt: drawingPrompt(weather), references, mode: "generate", isolatedLayer: true,
      })).bytes;
    const folder = layer === "window" ? "pet-window-weather" : "pet-weather";
    const r2Key = `private/${folder}/${pet.stickerId}/${weather.kind}-${weather.isDay ? "day" : "night"}-${crypto.randomUUID()}.png`;
    await getObjectStore().put(r2Key, { bytes, contentType: "image/png" });
    const published = await db.update(petWeatherArt).set({ state: "ready", r2Key, readyAt: new Date() })
      .where(and(eq(petWeatherArt.id, claimed.id), eq(petWeatherArt.claimedAt, claimed.claimedAt),
        eq(petWeatherArt.revisionId, revision.id)))
      .returning({ id: petWeatherArt.id });
    if (!published.length) {
      await getObjectStore().delete(r2Key).catch(() => undefined);
      return;
    }
    if (claimed.r2Key) await getObjectStore().delete(claimed.r2Key).catch(() => undefined);
    petLog("weather-art:drawn", { userId, stickerId: pet.stickerId, revisionId: revision.id, kind: weather.kind, isDay: weather.isDay, layer });
  } catch (error) {
    petLog("weather-art:failed", { userId, layer, error: describeError(error) });
    if (claimed) {
      await db.update(petWeatherArt).set({ state: "failed" })
        .where(and(eq(petWeatherArt.id, claimed.id), eq(petWeatherArt.claimedAt, claimed.claimedAt),
          eq(petWeatherArt.revisionId, claimed.revisionId)))
        .catch(() => undefined);
    }
  }
}

/**
 * Fits each of the sheet's four pieces snugly into its own cell of an even square sheet, so the app
 * can cut the cells apart and size each piece by its cell without guessing at the model's margins.
 */
async function windowSheet(drawn: Uint8Array): Promise<Uint8Array> {
  const sheet = await sharp(drawn).resize(WINDOW_CELL_SIZE * 2, WINDOW_CELL_SIZE * 2, { fit: "fill" }).png().toBuffer();
  const inner = WINDOW_CELL_SIZE - WINDOW_CELL_MARGIN * 2;
  const cells = await Promise.all([0, 1, 2, 3].map(async (index) => {
    const cell = await sharp(sheet).extract({
      left: (index % 2) * WINDOW_CELL_SIZE, top: Math.floor(index / 2) * WINDOW_CELL_SIZE,
      width: WINDOW_CELL_SIZE, height: WINDOW_CELL_SIZE,
    }).png().toBuffer();
    // An empty cell has nothing to trim to; it stays as drawn.
    const trimmed = await sharp(cell).trim({ threshold: 1 }).png().toBuffer().catch(() => cell);
    const fitted = await sharp(trimmed)
      .resize(inner, inner, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png()
      .toBuffer();
    return {
      input: fitted,
      left: (index % 2) * WINDOW_CELL_SIZE + WINDOW_CELL_MARGIN,
      top: Math.floor(index / 2) * WINDOW_CELL_SIZE + WINDOW_CELL_MARGIN,
    };
  }));
  const composed = await sharp({
    create: { width: WINDOW_CELL_SIZE * 2, height: WINDOW_CELL_SIZE * 2, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  }).composite(cells).png().toBuffer();
  return new Uint8Array(composed);
}

/**
 * Takes the right to draw one look, or nothing when it is drawn, being drawn, or failed recently.
 * The claim is conditional on the row as it was read, so two reads at once draw it once.
 */
async function claimLook(
  db: Database, stickerId: string, revisionId: string, weather: Weather, layer: PetWeatherArtLayer, now: Date,
) {
  const existing = await lookRow(db, stickerId, weather, layer);
  if (!existing) {
    return db.insert(petWeatherArt)
      .values({ id: crypto.randomUUID(), stickerId, revisionId, kind: weather.kind, isDay: weather.isDay, layer, state: "drawing", claimedAt: now })
      .onConflictDoNothing()
      .returning()
      .then(firstRow);
  }
  const age = now.getTime() - existing.claimedAt.getTime();
  if (existing.revisionId === revisionId && (existing.state === "ready"
    || (existing.state === "drawing" && age < DRAWING_STALE_MS)
    || (existing.state === "failed" && age < FAILED_RETRY_MS))) return undefined;
  return db.update(petWeatherArt).set({ state: "drawing", claimedAt: now, revisionId })
    .where(and(eq(petWeatherArt.id, existing.id), eq(petWeatherArt.claimedAt, existing.claimedAt),
      eq(petWeatherArt.revisionId, existing.revisionId), eq(petWeatherArt.state, existing.state)))
    .returning()
    .then(firstRow);
}

/**
 * The weather the caller's pet is in, drawn in its style, as a transparent PNG `size` pixels square:
 * the sticker, or for `window` the 2×2 sheet of sky pieces.
 * The ETag names the drawing and the size, so a client holding this exact one gets `bytes: null`.
 */
export async function getPetWeatherArt(
  db: Database,
  userId: string,
  size: number,
  ifNoneMatch?: string | null,
  expectedArtKey?: string | null,
  layer: PetWeatherArtLayer = "sticker",
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
  let playback;
  try {
    playback = await readablePlayback(db, userId, pet.stickerId);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
    throw error;
  }
  const weather = pet.signalsJson?.weather;
  const row = weather ? await lookRow(db, pet.stickerId, weather, layer) : undefined;
  if (row?.state !== "ready" || !row.r2Key || row.revisionId !== playback.revision.id) {
    throw new ApiError(404, "PET_WEATHER_ART_NOT_READY", "Your pet's weather has not been drawn yet.");
  }
  const key = artKey(row);
  if (expectedArtKey && expectedArtKey !== key) {
    throw new ApiError(409, "PET_WEATHER_ART_CHANGED", "Your pet's weather has changed. Refresh to see it.");
  }
  const etag = layer === "sticker" ? `"${key}-${size}"` : `"${key}-${layer}-${size}"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  const stored = await getObjectStore().get(row.r2Key);
  const bytes = await sharp(stored.bytes)
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  return { etag, bytes: new Uint8Array(bytes) };
}

/**
 * Drops every weather look drawn for a sticker, so the next read draws each again from its current
 * revision. Only for a pet that changed its art style enough that its old weather no longer matches;
 * the drawings are deleted after the rows, so a failure leaves at most an unreferenced object.
 */
export async function forgetPetWeatherArt(db: Database, stickerId: string): Promise<void> {
  const forgotten = await db.delete(petWeatherArt).where(eq(petWeatherArt.stickerId, stickerId))
    .returning({ r2Key: petWeatherArt.r2Key });
  const store = getObjectStore();
  await Promise.all(forgotten.flatMap((row) => row.r2Key ? [store.delete(row.r2Key).catch(() => undefined)] : []));
  petLog("weather-art:forgotten", { stickerId, looks: forgotten.length });
}
