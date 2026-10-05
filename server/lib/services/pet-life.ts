import { and, eq } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import type { Database } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { pickEvent } from "@/lib/pets/events";
import { petLog, petRandom } from "@/lib/pets/log";
import { catchIllness, hasRecovered, ILLNESS_EFFECTS, illnessChance } from "@/lib/pets/illness";
import { neglectEffects, neglectNote, withNeglect } from "@/lib/pets/neglect";
import { localDate, localHour, resolveSignals, signalEffects } from "@/lib/pets/signals";
import { forecastReminder, weatherChange } from "@/lib/pets/weather-news";
import { addEffects, applyEffects, personalizeEffects, preferenceEffects, ZERO_EFFECTS } from "@/lib/pets/stats";
import { ownerMoment, refreshActions } from "./pet-actions";
import { maybeStartEncounter } from "./pet-encounters";
import { refreshPetItems } from "./pet-items";
import { commitPetChange, currentStats, ensurePetIdentity, lastAttendedAt, lastFeltWeather, petRow, remindedForecastOn, type PetChange } from "./pet-state";
import { readablePlayback } from "./playback";

/** Time passing between visits: the pet rests, and misses its owner a little. */
const VISIT_DRIFT = { happiness: -3, hp: 0, energy: 6 };

/**
 * How long until the next visit, in milliseconds — 45 to 90 minutes, so visits do not land like
 * clockwork — or null when this run no longer holds the pet's life. Each visit can change the pet's
 * mood, and with it the actions on offer, so they come often enough for the pet to feel alive.
 *
 * `PET_LIFE_INTERVAL_MINUTES="2-5"` shortens the wait for debugging a life end to end.
 */
export async function planPetVisit(db: Database, userId: string, lifeId: string, token: string, now = new Date()): Promise<number | null> {
  const [min, max] = (process.env.PET_LIFE_INTERVAL_MINUTES ?? "45-90").split("-").map(Number);
  const minutes = min + petRandom() * ((Number.isFinite(max) ? max : min) - min);
  const delayMs = Math.max(60_000, Math.round(minutes * 60_000));
  const planned = await db.update(userPets).set({ nextEventAt: new Date(now.getTime() + delayMs) })
    .where(and(eq(userPets.userId, userId), eq(userPets.lifeId, lifeId), eq(userPets.lifeRunId, token)))
    .returning({ userId: userPets.userId });
  if (!planned.length) {
    petLog("life:ended", { userId, lifeId, token, reason: "replaced" });
    return null;
  }
  petLog("life:planned", { userId, lifeId, token, minutes: Math.round(minutes) });
  return delayMs;
}

/**
 * One visit from the life workflow: read the world, let time pass, roll a special event, and have
 * the pet say something about it. Returns false when this run no longer holds the pet's life, so
 * the workflow ends.
 *
 * Never throws for anything but a lost life: a visit that fails leaves the pet as it was, and the
 * next one is a few hours away anyway. Throwing would only make the step retry a half-done visit.
 */
export async function visitPet(
  db: Database,
  userId: string,
  lifeId: string,
  token: string,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
  now = new Date(),
): Promise<boolean> {
  let row = await petRow(db, userId);
  if (!row || row.lifeId !== lifeId || row.lifeRunId !== token) {
    petLog("life:ended", { userId, lifeId, token, reason: row ? "replaced" : "released" });
    return false;
  }
  try {
    let playback;
    try {
      playback = await readablePlayback(db, userId, row.stickerId);
    } catch (error) {
      // Not posable right now — a pack uninstalled, a sticker unpublished. The life goes on in
      // case it comes back; nothing happens to a pet nobody can see.
      if (error instanceof ApiError && error.status === 404) {
        petLog("life:visit-skipped", { userId, lifeId, reason: "not-posable" });
        return true;
      }
      throw error;
    }
    const configuration = playback.revision.playbackJson?.document.configuration;
    row = await ensurePetIdentity(db, row, async () => ({ title: playback.sticker.title, controls: configuration?.controls ?? [], image: null }));
    const identity = row.identityJson;
    const { signals, headlinesRefreshed } = await resolveSignals({
      context: row.contextJson, previous: row.signalsJson, previousAt: row.signalsUpdatedAt, identity, now, userId,
    });
    const eventContext = { identity, signals, hour: localHour(now, row.contextJson?.timeZone) };
    // The weather comes first: a dramatic change since the pet last felt it, or — in the evening, once
    // a day — tomorrow's forecast read out to its owner, takes the place of a random event.
    const reminderDate = localDate(now, row.contextJson?.timeZone);
    const weatherNews = weatherChange(await lastFeltWeather(db, userId, lifeId), signals.weather, identity)
      ?? forecastReminder({ signals, hour: eventContext.hour, date: reminderDate,
        alreadyReminded: await remindedForecastOn(db, userId, lifeId, reminderDate) });
    const picked = weatherNews ? null : pickEvent(eventContext, { special: true }, petRandom)!;
    const event = weatherNews
      ? { id: weatherNews.id, title: weatherNews.title, effects: weatherNews.effects, special: true, sickens: undefined }
      : picked!;
    const detail = weatherNews?.detail ?? picked!.detail(eventContext);
    const world = signalEffects(signals, identity);
    const preference = preferenceEffects(`${event.title} ${detail}`, identity);
    // An ill pet feels it on every visit until it is cured or gets over it; a well one may catch
    // something, more likely when the event was a soaking or a bad snack, or it is worn down.
    const illness = row.illnessJson;
    const recovered = illness && hasRecovered(illness, now) ? illness : null;
    const stillIll = illness && !recovered ? illness : null;
    const caught = !illness && petRandom() < illnessChance({
      hp: currentStats(row).hp, maxHp: identity?.maxHp ?? 100, eventSickens: event.sickens,
    }) ? catchIllness(now, petRandom) : null;
    const raw = addEffects(VISIT_DRIFT, world.effects, event.effects, preference.effects, stillIll ? ILLNESS_EFFECTS : ZERO_EFFECTS);
    // Left alone too long, the pet pines: its happiness and HP slip on every visit until its owner is back.
    const attendedAt = (await lastAttendedAt(db, userId, lifeId)) ?? row.createdAt;
    const hoursAway = Math.max(0, (now.getTime() - attendedAt.getTime()) / 3_600_000);
    const neglect = neglectEffects(hoursAway);
    const effects = withNeglect(personalizeEffects(raw, identity), neglect);
    const eventDetail = [
      detail,
      neglect ? neglectNote(hoursAway) : "",
      stillIll ? `Still ill with ${stillIll.name}.` : "",
      caught ? `Came down with ${caught.name}.` : "",
      recovered ? `Got over ${recovered.name}.` : "",
    ].filter(Boolean).join(" ");
    const illnessChanges: PetChange[] = [
      ...(caught ? [{ kind: "illness" as const, title: "Fell ill", detail: `Came down with ${caught.name}.`,
        effects: ZERO_EFFECTS, debug: { source: "life-workflow", eventId: event.id, sickens: event.sickens ?? 0 } }] : []),
      ...(recovered ? [{ kind: "illness" as const, title: "Got better", detail: `Got over ${recovered.name} on its own.`,
        effects: ZERO_EFFECTS, debug: { source: "life-workflow", since: recovered.since } }] : []),
    ];

    let status = row.statusJson;
    let narrated = true;
    try {
      const answer = await getAiProvider().narratePetEvent({
        petTitle: playback.sticker.title, identity, signals, event: { title: event.title, detail: eventDetail },
        stats: currentStats(row), controls: configuration?.controls ?? [], current: row.statusJson?.values ?? null,
        ...ownerMoment(row.contextJson, now),
      });
      status = {
        values: configuration ? normalizedControlValues(configuration, { ...row.statusJson?.values, ...answer.values }) : {},
        caption: answer.caption.trim(),
        animateEverySeconds: answer.animateEverySeconds,
        musings: answer.musings,
      };
    } catch (error) {
      narrated = false;
      petLog("life:narrate-failed", { userId, lifeId, event: event.id, error: describeError(error) });
    }

    // A new mood brings new things to do; a visit the pet did not narrate leaves its actions alone.
    const actions = narrated && status
      ? await refreshActions(db, row, playback.sticker, playback.revision, {
        stats: applyEffects(currentStats(row), effects, identity), mood: `${status.caption} (${event.title} — ${eventDetail})`, signals,
      })
      : undefined;
    const committed = await commitPetChange(db, userId, {
      lifeId,
      where: eq(userPets.lifeRunId, token),
      set: {
        ...(narrated && status ? { statusJson: status, statusUpdatedAt: now } : {}),
        ...(actions ? { actionsJson: actions } : {}),
        signalsJson: signals,
        ...(headlinesRefreshed ? { signalsUpdatedAt: now } : {}),
        ...(caught ? { illnessJson: caught } : recovered ? { illnessJson: null } : {}),
        lifeTickAt: now,
      },
      changes: [{
        kind: event.special ? "special" : "random",
        title: event.title,
        detail: narrated && status ? `${eventDetail} “${status.caption}”` : eventDetail,
        effects,
        signals,
        debug: {
          source: "life-workflow",
          eventId: event.id,
          eventEffects: event.effects,
          // `reminderDate` at the top level is what `remindedForecastOn` looks for.
          ...(weatherNews ? { weather: weatherNews.debug, ...(weatherNews.id === "forecast-reminder" ? { reminderDate } : {}) } : {}),
          drift: VISIT_DRIFT,
          hoursAway: Math.round(hoursAway * 10) / 10,
          neglect,
          worldEffects: world.effects,
          worldReasons: world.reasons,
          preference: preference.matched,
          energyMultiplier: identity?.energyMultiplier ?? 1,
          hour: eventContext.hour,
          illness: stillIll?.name ?? null,
          narrated,
          token,
        },
      }, ...illnessChanges],
    });
    if (!committed) return (await petRow(db, userId))?.lifeRunId === token;
    await refreshPetItems(db, userId, now);
    // Once a day, at a moment of its own, the pet runs into something its owner has to decide.
    await maybeStartEncounter(db, userId, now);
    petLog("life:visited", { userId, lifeId, event: event.id, effects, after: committed.after });
    if (narrated) await notify(db, userId).catch((error) => petLog("life:notify-failed", { userId, error: describeError(error) }));
    return true;
  } catch (error) {
    petLog("life:visit-failed", { userId, lifeId, error: describeError(error) });
    return true;
  }
}

/** The run's week is up. It lets go of the token so the cron starts a fresh run with a short history. */
export async function retirePetLife(db: Database, userId: string, lifeId: string, token: string): Promise<void> {
  await db.update(userPets).set({ lifeRunId: null })
    .where(and(eq(userPets.userId, userId), eq(userPets.lifeId, lifeId), eq(userPets.lifeRunId, token)));
  petLog("life:retired", { userId, lifeId, token });
}
