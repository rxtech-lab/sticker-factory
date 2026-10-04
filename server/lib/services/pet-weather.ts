// The weather where the owner is, drawn in the pet's own art style: a sun, a rain cloud, a moon,
// looking like it came off the same sheet as the pet. The Pet tab stands it behind the pet and
// animates it; the widget shows it beside the pet.
//
// Drawn once per look — the pet's playback revision, the kind of weather, day or night — and kept,
// so a rainy Tuesday costs nothing if it already rained on Monday. Drawing happens after a response
// is out; until it lands the client shows the weather as a symbol.

import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetSignalsV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petWeatherArt, type PetWeatherArtRow } from "@/lib/db/schema";
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
  return createHash("sha256").update(`${row.id}:${row.readyAt?.toISOString() ?? ""}`).digest("hex").slice(0, 24);
}

async function lookRow(db: Database, revisionId: string, weather: Pick<Weather, "kind" | "isDay">) {
  return db.select().from(petWeatherArt)
    .where(and(eq(petWeatherArt.revisionId, revisionId), eq(petWeatherArt.kind, weather.kind), eq(petWeatherArt.isDay, weather.isDay)))
    .then(firstRow);
}

/** `PetResponseV1.pet.weatherArt`: the drawn look for the weather now, or null until it is drawn. */
export async function serializePetWeatherArt(db: Database, revisionId: string, signals: PetSignalsV1 | null) {
  const weather = signals?.weather;
  if (!weather) return null;
  const row = await lookRow(db, revisionId, weather);
  if (row?.state !== "ready" || !row.r2Key) return null;
  return { kind: weather.kind, isDay: weather.isDay, key: artKey(row) };
}

/**
 * Draws the weather the caller's pet is in now, unless that look is already drawn or being drawn.
 *
 * Runs after a response, so it never throws: a pet without its weather drawn still has the symbol.
 */
export async function drawPetWeatherArt(db: Database, userId: string, now = new Date()): Promise<void> {
  let claimed: PetWeatherArtRow | undefined;
  try {
    const pet = await petRow(db, userId);
    const weather = pet?.signalsJson?.weather;
    if (!pet || !weather) return;
    const { revision } = await readablePlayback(db, userId, pet.stickerId);
    claimed = await claimLook(db, revision.id, weather, now);
    if (!claimed) return;
    const style = await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId);
    const drawn = await getAiProvider().generateStickerImage({
      prompt: drawingPrompt(weather),
      references: style ? [{ ...style, label: "the pet character, for its art style only" }] : [],
      mode: "generate",
      isolatedLayer: true,
    });
    const r2Key = `private/pet-weather/${revision.id}/${weather.kind}-${weather.isDay ? "day" : "night"}-${claimed.id}.png`;
    await getObjectStore().put(r2Key, { bytes: drawn.bytes, contentType: "image/png" });
    await db.update(petWeatherArt).set({ state: "ready", r2Key, readyAt: new Date() })
      .where(and(eq(petWeatherArt.id, claimed.id), eq(petWeatherArt.claimedAt, claimed.claimedAt)));
    petLog("weather-art:drawn", { userId, revisionId: revision.id, kind: weather.kind, isDay: weather.isDay });
  } catch (error) {
    petLog("weather-art:failed", { userId, error: describeError(error) });
    if (claimed) {
      await db.update(petWeatherArt).set({ state: "failed" })
        .where(and(eq(petWeatherArt.id, claimed.id), eq(petWeatherArt.claimedAt, claimed.claimedAt)))
        .catch(() => undefined);
    }
  }
}

/**
 * Takes the right to draw one look, or nothing when it is drawn, being drawn, or failed recently.
 * The claim is conditional on the row as it was read, so two reads at once draw it once.
 */
async function claimLook(db: Database, revisionId: string, weather: Weather, now: Date) {
  const existing = await lookRow(db, revisionId, weather);
  if (!existing) {
    return db.insert(petWeatherArt)
      .values({ id: crypto.randomUUID(), revisionId, kind: weather.kind, isDay: weather.isDay, state: "drawing", claimedAt: now })
      .onConflictDoNothing()
      .returning()
      .then(firstRow);
  }
  const age = now.getTime() - existing.claimedAt.getTime();
  if (existing.state === "ready" || (existing.state === "drawing" && age < DRAWING_STALE_MS)
    || (existing.state === "failed" && age < FAILED_RETRY_MS)) return undefined;
  return db.update(petWeatherArt).set({ state: "drawing", claimedAt: now })
    .where(and(eq(petWeatherArt.id, existing.id), eq(petWeatherArt.claimedAt, existing.claimedAt)))
    .returning()
    .then(firstRow);
}

/**
 * The weather the caller's pet is in, drawn in its style, as a transparent PNG `size` pixels square.
 * The ETag names the drawing and the size, so a client holding this exact one gets `bytes: null`.
 */
export async function getPetWeatherArt(
  db: Database,
  userId: string,
  size: number,
  ifNoneMatch?: string | null,
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
  let revisionId: string;
  try {
    revisionId = (await readablePlayback(db, userId, pet.stickerId)).revision.id;
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
    throw error;
  }
  const weather = pet.signalsJson?.weather;
  const row = weather ? await lookRow(db, revisionId, weather) : undefined;
  if (row?.state !== "ready" || !row.r2Key) {
    throw new ApiError(404, "PET_WEATHER_ART_NOT_READY", "Your pet's weather has not been drawn yet.");
  }
  const etag = `"${artKey(row)}-${size}"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  const stored = await getObjectStore().get(row.r2Key);
  const bytes = await sharp(stored.bytes)
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();
  return { etag, bytes: new Uint8Array(bytes) };
}
