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
import { localHour, resolveSignals, signalEffects } from "@/lib/pets/signals";
import { addEffects, applyEffects, personalizeEffects, preferenceEffects } from "@/lib/pets/stats";
import { refreshActions } from "./pet-actions";
import { commitPetChange, currentStats, ensurePetIdentity, petRow } from "./pet-state";
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
    const event = pickEvent(eventContext, { special: true }, petRandom)!;
    const detail = event.detail(eventContext);
    const world = signalEffects(signals, identity);
    const preference = preferenceEffects(`${event.title} ${detail}`, identity);
    const raw = addEffects(VISIT_DRIFT, world.effects, event.effects, preference.effects);
    const effects = personalizeEffects(raw, identity);

    let status = row.statusJson;
    let narrated = true;
    try {
      const answer = await getAiProvider().narratePetEvent({
        petTitle: playback.sticker.title, identity, signals, event: { title: event.title, detail },
        stats: currentStats(row), controls: configuration?.controls ?? [], current: row.statusJson?.values ?? null,
      });
      status = {
        values: configuration ? normalizedControlValues(configuration, { ...row.statusJson?.values, ...answer.values }) : {},
        caption: answer.caption.trim(),
      };
    } catch (error) {
      narrated = false;
      petLog("life:narrate-failed", { userId, lifeId, event: event.id, error: describeError(error) });
    }

    // A new mood brings new things to do; a visit the pet did not narrate leaves its actions alone.
    const actions = narrated && status
      ? await refreshActions(db, row, playback.sticker, playback.revision, {
        stats: applyEffects(currentStats(row), effects, identity), mood: `${status.caption} (${event.title} — ${detail})`, signals,
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
        lifeTickAt: now,
      },
      changes: [{
        kind: event.special ? "special" : "random",
        title: event.title,
        detail: narrated && status ? `${detail} “${status.caption}”` : detail,
        effects,
        signals,
        debug: {
          source: "life-workflow",
          eventId: event.id,
          eventEffects: event.effects,
          drift: VISIT_DRIFT,
          worldEffects: world.effects,
          worldReasons: world.reasons,
          preference: preference.matched,
          energyMultiplier: identity?.energyMultiplier ?? 1,
          hour: eventContext.hour,
          narrated,
          token,
        },
      }],
    });
    if (!committed) return (await petRow(db, userId))?.lifeRunId === token;
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
