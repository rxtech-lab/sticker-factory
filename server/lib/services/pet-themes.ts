import { backgroundAnimationEngine } from "./animation-settings";
import { generateSceneArt, sceneDesignCheckpoint } from "@/lib/pets/scene-art";
import { and, asc, eq, isNull, lt, lte, or } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { AiPetThemeChoice } from "@/lib/ai/gateway-contracts";
import type { PetSignalsV1, PetThemesV1, PetThemeV1 } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petThemes, userPets, type PetRoomFixtures, type PetThemeRow, type PetThemeUsage } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { currentLocation, distanceKm, isTraveling } from "@/lib/pets/home";
import { petLog } from "@/lib/pets/log";
import { renderThemeArt } from "@/lib/pets/room-art";
import { ZERO_EFFECTS } from "@/lib/pets/stats";
import {
  accrueThemeUsage, describeThemeEffects, isLimitedTheme, minutesLeftToday, sanitizeTheme, THEME_DISCOVERY_INTERVAL_MS,
  THEME_DISCOVERY_MAX, THEME_REVISITABLE_MAX, themeAvailability,
} from "@/lib/pets/themes";
import { getObjectStore } from "@/lib/storage/r2";
import { ownerMoment, sentStickerImage } from "./pet-actions";
import { commitPetChange, currentStats, petRow, type PetChange, type PetRow } from "./pet-state";
import { lastPublishedPlayback } from "./playback";

/** A search that has not published within this long is taken to have died, and may be tried again. */
const RETRY_AFTER_MS = 10 * 60 * 1000;
/** A stay this long earns a place's full effect; a shorter one earns its share. */
const FULL_STAY_MINUTES = 60;

function artPath(userId: string, artKey: string): string {
  return `private/pet-themes/${userId}/${artKey}.webp`;
}

async function deleteArt(userId: string, artKeys: string[]): Promise<void> {
  await Promise.all(artKeys.flatMap((key) => [artPath(userId, key), artPath(userId, key).replace(".webp", ".reference.png"), artPath(userId, key).replace(".webp", ".svg.json")].map(path => getObjectStore().delete(path).catch(() => undefined))));
}

type World = { context: PetRow["contextJson"]; signals: PetSignalsV1 | null; usage: PetThemeUsage | null; now: Date };

function worldOf(pet: PetRow, now: Date): World {
  return { context: pet.contextJson, signals: pet.signalsJson, usage: pet.themeUsageJson, now };
}

function isExpired(row: PetThemeRow, now: Date): boolean {
  return row.state === "expired" || (!!row.expiresAt && row.expiresAt <= now);
}

function serializeTheme(row: PetThemeRow, world: World): PetThemeV1 {
  const availability = themeAvailability(row, world);
  return {
    id: row.id, title: row.title, description: row.description, category: row.category,
    limited: isLimitedTheme(row.category), effects: row.effectsJson,
    rules: row.rulesJson,
    artKey: row.artKey, fixtures: row.fixturesJson ?? null, expiresAt: row.expiresAt?.toISOString() ?? null, expired: isExpired(row, world.now),
    available: availability.available, unavailableReason: availability.available ? null : availability.reason,
    minutesLeftToday: minutesLeftToday(row, world.usage, world.now, world.context?.timeZone),
    discoveredAt: row.createdAt.toISOString(),
  };
}

/** The place the pet has gone, as `GET /api/v1/pet` names it; null at home, or once it has expired. */
export function serializePetTheme(
  row: Pick<PetRow, "theme">, now = new Date(),
): { id: string; title: string; artKey: string; category: PetThemeRow["category"]; fixtures: PetRoomFixtures | null } | null {
  const { theme } = row;
  return theme && !isExpired(theme, now)
    ? { id: theme.id, title: theme.title, artKey: theme.artKey, category: theme.category, fixtures: theme.fixturesJson ?? null } : null;
}

/**
 * Ends limited places whose time is up, and a trip's places once the owner is back home. Once
 * expired a place is gone for good: kept to look back on, never gone to again.
 */
async function expireThemes(db: Database, pet: PetRow, now: Date): Promise<void> {
  const expired = await db.update(petThemes).set({ state: "expired" })
    .where(and(eq(petThemes.userId, pet.userId), eq(petThemes.state, "available"), lte(petThemes.expiresAt, now)))
    .returning({ id: petThemes.id });
  const home = currentLocation(pet.contextJson, now) && !isTraveling(pet.contextJson, now);
  const ended = home
    ? await db.update(petThemes).set({ state: "expired" })
      .where(and(eq(petThemes.userId, pet.userId), eq(petThemes.state, "available"), eq(petThemes.category, "travel")))
      .returning({ id: petThemes.id })
    : [];
  if (expired.length || ended.length) {
    petLog("themes:expired", { userId: pet.userId, timeUp: expired.map((row) => row.id), tripOver: ended.map((row) => row.id) });
  }
}

async function themeRows(db: Database, userId: string): Promise<PetThemeRow[]> {
  return db.select().from(petThemes).where(eq(petThemes.userId, userId)).orderBy(asc(petThemes.createdAt));
}

/**
 * What the pet's agent should go looking for now: a place on the owner's trip when they are far from
 * home and the pet has none there, a clinic when the pet is hurt or ill and has none, and once a day,
 * everyday places, until it knows enough of them.
 */
function discoveryNeeds(pet: PetRow, rows: PetThemeRow[], now: Date): { needs: Array<"travel" | "accident">; everyday: boolean } {
  const open = rows.filter((row) => !isExpired(row, now));
  const here = currentLocation(pet.contextJson, now);
  const tripCovered = open.some((row) => row.category === "travel" && row.rulesJson.place && here
    && distanceKm(here, row.rulesJson.place) <= row.rulesJson.place.radiusKm);
  const hurt = !!pet.illnessJson || currentStats(pet).hp < (pet.identityJson?.maxHp ?? 100) * 0.25;
  const needs = [
    ...(isTraveling(pet.contextJson, now) && !tripCovered ? ["travel" as const] : []),
    ...(hurt && !open.some((row) => row.category === "accident") ? ["accident" as const] : []),
  ];
  const revisitable = rows.filter((row) => !isLimitedTheme(row.category)).length;
  const everyday = revisitable < THEME_REVISITABLE_MAX
    && (!pet.themesDiscoveredAt || pet.themesDiscoveredAt.getTime() <= now.getTime() - THEME_DISCOVERY_INTERVAL_MS);
  return { needs, everyday };
}

/** The places the pet knows, newest first with the expired ones last, and which it is at. */
export async function listPetThemes(db: Database, userId: string, now = new Date()): Promise<PetThemesV1> {
  const pet = await petRow(db, userId);
  if (!pet) return { activeThemeId: null, themes: [], discovering: false, traveling: false, hasLocation: false };
  const rows = await themeRows(db, userId);
  const world = worldOf(pet, now);
  const themes = rows.map((row) => serializeTheme(row, world))
    .sort((a, b) => Number(a.expired) - Number(b.expired) || b.discoveredAt.localeCompare(a.discoveredAt));
  const { needs, everyday } = discoveryNeeds(pet, rows, now);
  return {
    activeThemeId: serializePetTheme(pet, now)?.id ?? null,
    themes,
    // Every read of places that are due looks for them, so a due search is one under way.
    discovering: !!pet.lifeId && (needs.length > 0 || everyday),
    traveling: isTraveling(pet.contextJson, now),
    hasLocation: !!currentLocation(pet.contextJson, now),
  };
}

/**
 * Has the pet's agent look for new places when it is due — a trip or an accident at once, everyday
 * places once a day — and draws each in the pet's style. Run after a visit, after the phone reports
 * where it is, and after a read of the places, so a trip has its place drawn in the background.
 *
 * Claimed first, so two triggers search once. Never throws: a search that fails is tried again
 * once the claim cools down.
 */
export async function refreshPetThemes(db: Database, userId: string, now = new Date()): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) return;
  await expireThemes(db, pet, now);
  const rows = await themeRows(db, userId);
  const { needs, everyday } = discoveryNeeds(pet, rows, now);
  if (!needs.length && !everyday) return;
  const [claimed] = await db.update(userPets).set({ themesClaimedAt: now })
    .where(and(eq(userPets.userId, userId),
      or(isNull(userPets.themesClaimedAt), lt(userPets.themesClaimedAt, new Date(now.getTime() - RETRY_AFTER_MS)))))
    .returning({ userId: userPets.userId });
  if (!claimed) return;
  const drawn: string[] = [];
  const clearCheckpoints: (() => Promise<void>)[] = [];
  try {
    const { sticker, revision } = await lastPublishedPlayback(db, userId, pet.stickerId);
    const style = await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId);
    const requestedEngine = await backgroundAnimationEngine(db, userId);
    const location = currentLocation(pet.contextJson, now);
    const home = pet.contextJson?.home;
    const designBatch = await sceneDesignCheckpoint(userId, "themes", `${pet.stickerId}:${revision.id}:${needs.join(",")}`, async () => ({ engine: requestedEngine, designs: await getAiProvider().discoverPetThemes({
      petTitle: sticker.title,
      controls: revision.playbackJson?.document.configuration?.controls ?? [],
      image: style,
      identity: pet.identityJson,
      signals: pet.signalsJson,
      stats: currentStats(pet),
      mood: pet.statusJson?.caption ?? null,
      illness: pet.illnessJson?.name ?? null,
      known: rows.map((row) => ({ title: row.title, category: row.category })),
      needs,
      max: needs.length + (everyday ? THEME_DISCOVERY_MAX : 0),
      traveling: needs.includes("travel") && location && home ? { distanceKm: distanceKm(location, home) } : null,
      hasLocation: !!location,
      ...ownerMoment(pet.contextJson, now),
    }) }));
    const { engine, designs: designed } = designBatch.value;
    const known = new Set(rows.map((row) => row.title.toLocaleLowerCase()));
    const themes = designed
      // A trip or a clinic only when the moment calls for one; everyday places and events once a day.
      .filter((theme) => theme.category === "travel" || theme.category === "accident" ? needs.includes(theme.category) : everyday)
      .map((theme) => sanitizeTheme(theme, { location, now }))
      .filter((theme) => theme !== null)
      .filter((theme) => {
        const title = theme.title.toLocaleLowerCase();
        if (known.has(title)) return false;
        known.add(title);
        return true;
      });
    const missing = needs.filter((need) => !themes.some((theme) => theme.category === need));
    if (missing.length) petLog("themes:needs-unmet", { userId, missing });
    // Drawn side by side; a place that could not be drawn is left out rather than shown blank.
    const drawnThemes = (await Promise.all(themes.map(async (theme) => {
      try {
        const draw = () => getAiProvider().generatePetThemeArt({ scene: theme.scene, reference: style, ...(engine === "svg" ? { engine } : {}) });
        const vector = engine === "svg" ? await generateSceneArt({ userId, kind: "themes", brief: theme.scene, style, draw }) : null;
        const { bytes, fixtures } = vector ?? await renderThemeArt((await draw()).bytes);
        if (!fixtures.clock || !fixtures.weather || !fixtures.status) {
          petLog("themes:missing-fixture", {
            userId, title: theme.title, clock: !!fixtures.clock, weather: !!fixtures.weather, status: !!fixtures.status,
          });
        }
        const artKey = crypto.randomUUID();
        drawn.push(artKey);
        await getObjectStore().put(artPath(userId, artKey), { bytes, contentType: "image/webp" });
        if (vector) {
          await getObjectStore().put(artPath(userId, artKey).replace(".webp", ".reference.png"), { bytes: vector.referenceBytes, contentType: "image/png" });
          await getObjectStore().put(artPath(userId, artKey).replace(".webp", ".svg.json"), { bytes: Buffer.from(JSON.stringify(vector.scene)), contentType: "application/json" });
          clearCheckpoints.push(vector.clearCheckpoint);
        }
        return { ...theme, artKey, fixtures, scene: vector?.scene ?? null };
      } catch (error) {
        petLog("themes:draw-failed", { userId, title: theme.title, error: describeError(error) });
        return null;
      }
    }))).filter((theme) => theme !== null);
    if (engine === "svg" && drawnThemes.length !== themes.length) throw new Error("SVG place batch is incomplete; saved references will be reused on retry");
    if (themes.length && !drawnThemes.length) throw new Error("No place could be drawn");

    const published = await db.transaction(async (tx) => {
      const released = await tx.update(userPets)
        .set({ themesClaimedAt: null, ...(everyday ? { themesDiscoveredAt: now } : {}) })
        .where(and(eq(userPets.userId, userId), eq(userPets.themesClaimedAt, now)))
        .returning({ userId: userPets.userId });
      if (!released.length) return false;
      if (drawnThemes.length) {
        await tx.insert(petThemes).values(drawnThemes.map((theme) => ({
          id: crypto.randomUUID(), userId, title: theme.title, description: theme.description, category: theme.category,
          effectsJson: theme.effects, rulesJson: theme.rules, artKey: theme.artKey, fixturesJson: theme.fixtures, sceneJson: theme.scene,
          state: "available" as const,
          expiresAt: theme.expiresAt, createdAt: now,
        })));
      }
      return true;
    });
    if (!published) {
      await deleteArt(userId, drawn);
      return;
    }
    await designBatch.clear().catch(() => undefined);
    await Promise.all(clearCheckpoints.map(clear => clear().catch(() => undefined)));
    petLog("themes:discovered", { userId, lifeId: pet.lifeId, needs, everyday,
      themes: drawnThemes.map((theme) => ({ title: theme.title, category: theme.category, effects: theme.effects, rules: theme.rules })) });
  } catch (error) {
    await deleteArt(userId, drawn);
    // The claim is kept: the next trigger tries again once it cools down, not on every poll.
    petLog("themes:refresh-failed", { userId, error: describeError(error) });
  }
}

/**
 * The time the pet spent at a place since it was last counted, as a diary line: the place's effect,
 * in proportion to the stay up to a full hour. Null when the stay was too short to do anything.
 */
function timeSpent(theme: PetThemeRow, minutes: number): PetChange | null {
  const share = Math.min(1, minutes / FULL_STAY_MINUTES);
  const effects = {
    happiness: Math.round(theme.effectsJson.happiness * share),
    hp: Math.round(theme.effectsJson.hp * share),
    energy: Math.round(theme.effectsJson.energy * share),
  };
  if (!effects.happiness && !effects.hp && !effects.energy) return null;
  return {
    kind: "theme",
    title: `Time at ${theme.title}`,
    detail: `${describeThemeEffects(effects)} from ${minutes} minutes at ${theme.title}.`,
    // The place's own effect, as it says on the sign: not scaled by the pet's energy multiplier.
    effects: { ...effects, gold: 0 },
    debug: { source: "theme", themeId: theme.id, minutes, share: Math.round(share * 100) / 100 },
  };
}

/** The pet leaving one place for another, or for home, as a diary line. */
function moveLine(from: PetThemeRow | null, to: PetThemeRow | null, reason: string, source: string): PetChange {
  return {
    kind: "theme",
    title: to ? `Went to ${to.title}` : "Came home",
    detail: reason,
    effects: ZERO_EFFECTS,
    debug: { source, from: from?.id ?? null, to: to?.id ?? null },
  };
}

/**
 * Where the pet is, and the time it spent there since it was last counted, as a diary line — what
 * any move away from it, or a visit, settles first.
 */
function settleStay(pet: PetRow, usage: PetThemeUsage): { here: PetThemeRow | null; spent: PetChange | null } {
  const here = pet.themeId ? pet.theme : null;
  if (!here || !pet.themeUsageJson) return { here, spent: null };
  const before = pet.themeUsageJson.date === usage.date ? pet.themeUsageJson.minutes[here.id] ?? 0 : 0;
  return { here, spent: timeSpent(here, Math.max(0, (usage.minutes[here.id] ?? 0) - before)) };
}

/**
 * The pet's places on one of its life visits: the time it spent where it is counts, and its effect
 * lands; a place it can no longer be at sends it home; and its agent decides whether it should go
 * somewhere else now. What the visit commits alongside its other changes, and a line for the
 * narration about where the pet is.
 *
 * Never throws: a visit whose places could not be weighed leaves the pet where it is.
 */
export async function planThemeVisit(
  db: Database,
  pet: PetRow,
  input: { petTitle: string; signals: PetSignalsV1; now: Date },
): Promise<{ set: { themeId?: string | null; themeUsageJson: PetThemeUsage }; changes: PetChange[]; note: string | null }> {
  const { now, signals } = input;
  const timeZone = pet.contextJson?.timeZone;
  const usage = accrueThemeUsage(pet.themeUsageJson, pet.themeId, now, timeZone);
  const { here, spent } = settleStay(pet, usage);
  const changes: PetChange[] = spent ? [spent] : [];
  try {
    await expireThemes(db, pet, now);
    const rows = await themeRows(db, pet.userId);
    const world: World = { context: pet.contextJson, signals, usage, now };
    const current = here ? rows.find((row) => row.id === here.id) ?? null : null;
    const fresh = current && !isExpired(current, now) ? themeAvailability(current, world) : null;
    let destination: { to: PetThemeRow | null; reason: string; source: string } | null = null;
    if (current && (!fresh || !fresh.available)) {
      const why = fresh && !fresh.available ? fresh.reason : "This was a one-time place, and it has passed.";
      destination = { to: null, reason: `Had to leave ${current.title}. ${why}`, source: "theme-rules" };
    }
    if (!destination) {
      const candidates = rows.filter((row) => row.id !== current?.id && !isExpired(row, now) && themeAvailability(row, world).available);
      if (candidates.length || current) {
        let choice: AiPetThemeChoice = { move: false };
        try {
          choice = await getAiProvider().choosePetTheme({
            petTitle: input.petTitle, identity: pet.identityJson, signals, stats: currentStats(pet),
            illness: pet.illnessJson?.name ?? null, traveling: isTraveling(pet.contextJson, now),
            current: current ? { id: current.id, title: current.title, category: current.category, minutesHere: usage.minutes[current.id] ?? 0 } : null,
            candidates: candidates.map((row) => ({
              id: row.id, title: row.title, description: row.description, category: row.category, effects: row.effectsJson,
              minutesLeftToday: minutesLeftToday(row, usage, now, timeZone),
              expiresInHours: row.expiresAt ? Math.max(0, Math.round((row.expiresAt.getTime() - now.getTime()) / 3_600_000)) : null,
            })),
            ...ownerMoment(pet.contextJson, now),
          });
        } catch (error) {
          petLog("themes:choose-failed", { userId: pet.userId, error: describeError(error) });
        }
        if (choice.move && choice.themeId !== (current?.id ?? null)) {
          const to = choice.themeId ? candidates.find((row) => row.id === choice.themeId) ?? null : null;
          // An id the agent made up is no place at all: the pet stays where it is.
          if (to || choice.themeId === null) destination = { to, reason: choice.reason, source: "theme-agent" };
        }
      }
    }
    const after = destination ? destination.to : current;
    if (destination) {
      changes.push(moveLine(current, destination.to, destination.reason, destination.source));
      petLog("themes:moved", { userId: pet.userId, from: current?.id ?? null, to: destination.to?.id ?? null,
        source: destination.source, reason: destination.reason });
    }
    return {
      set: { ...(destination ? { themeId: destination.to?.id ?? null } : {}), themeUsageJson: usage },
      changes,
      note: after ? `${input.petTitle} is at ${after.title}: ${after.description}` : null,
    };
  } catch (error) {
    petLog("themes:visit-failed", { userId: pet.userId, error: describeError(error) });
    return { set: { themeUsageJson: usage }, changes, note: null };
  }
}

/**
 * Takes the pet to a place it knows, or home with null, when the place's rules allow it now. The
 * time it spent where it was counts first. An expired place is gone for good.
 */
export async function setPetTheme(
  db: Database,
  userId: string,
  themeId: string | null,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
  now = new Date(),
): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  if (themeId === (pet.themeId ?? null)) return;
  let to: PetThemeRow | null = null;
  if (themeId) {
    await expireThemes(db, pet, now);
    to = await db.select().from(petThemes).where(and(eq(petThemes.id, themeId), eq(petThemes.userId, userId))).then(firstRow) ?? null;
    if (!to) throw new ApiError(404, "PET_THEME_NOT_FOUND", "Your pet does not know this place.");
    if (isExpired(to, now)) throw new ApiError(410, "PET_THEME_EXPIRED", "This was a one-time place, and it has passed.");
    const availability = themeAvailability(to, worldOf(pet, now));
    if (!availability.available) throw new ApiError(422, "PET_THEME_UNAVAILABLE", availability.reason);
  }
  const usage = accrueThemeUsage(pet.themeUsageJson, pet.themeId, now, pet.contextJson?.timeZone);
  const { here, spent } = settleStay(pet, usage);
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId,
    set: { themeId, themeUsageJson: usage },
    changes: [
      ...(spent ? [spent] : []),
      moveLine(here, to, to ? `You took your pet to ${to.title}.` : "You brought your pet home.", "theme-owner"),
    ],
  });
  if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  petLog("themes:owner-moved", { userId, lifeId: pet.lifeId, from: pet.themeId, to: themeId });
  await notify(db, userId).catch((error) => petLog("themes:notify-failed", { userId, error: describeError(error) }));
}

/** One place's drawing, for the owner who can see it. */
export async function getPetThemeArt(
  db: Database, userId: string, themeId: string, ifNoneMatch?: string | null,
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const theme = await db.select({ artKey: petThemes.artKey }).from(petThemes)
    .where(and(eq(petThemes.id, themeId), eq(petThemes.userId, userId)))
    .then(firstRow);
  if (!theme) throw new ApiError(404, "PET_THEME_NOT_FOUND", "Your pet does not know this place.");
  const etag = `"${theme.artKey}-webp-v1"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };
  const art = await getObjectStore().get(artPath(userId, theme.artKey));
  return { etag, bytes: art.bytes };
}

