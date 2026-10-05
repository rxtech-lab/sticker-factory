import { createHash } from "node:crypto";
import { and, eq, inArray, isNull } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { PetAction } from "@/lib/ai/gateway-contracts";
import type { PetContextStoredV1, PetContextV1, PetIdentityV1, PetInteractionRequest, PetSignalsV1, RecordPetSendRequest, SendPetPhotoRequest, SetPetRequest, SharePetContentRequest } from "@/lib/contracts/api";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import { canonicalJson, resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { generationJobs, packInstalls, petEvents, stickerPackItems, stickerPacks, stickerRevisions, stickers, userPets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError, traceEvent } from "@/lib/observability/trace";
import type { RenderAssets } from "@/lib/render/document-svg";
import { renderPosePng } from "@/lib/render/renditions";
import { downscaleForModelInput, getObjectStore } from "@/lib/storage/r2";
import { goldBalance } from "@/lib/subscription/gold";
import { pickEvent, SEND_EVENT_CHANCE } from "@/lib/pets/events";
import { buildIdentity, fallbackIdentity } from "@/lib/pets/identity";
import { petLog, petRandom } from "@/lib/pets/log";
import { localHour, mergeContext, resolveSignals, signalEffects } from "@/lib/pets/signals";
import { isWalkPayoutDue, walkReward } from "@/lib/pets/walk";
import { dailyGold } from "@/lib/pets/daily-gold";
import { roomComfortDate } from "@/lib/pets/rooms";
import { addEffects, applyEffects, initialStats, personalizeEffects, preferenceEffects, withoutGold, ZERO_EFFECTS } from "@/lib/pets/stats";
import { getReadyOwnedAssets } from "./assets";
import { generateActions, ownerMoment, refreshActions, sentStickerImage } from "./pet-actions";
import { canEvolve, serializePetEvolution, startPetEvolution } from "./pet-evolution";
import { openEncounter, serializeEncounter } from "./pet-encounters";
import { drawPetWeatherArt, serializePetWeatherArt } from "./pet-weather";
import { commitPetChange, currentStats, ensurePetIdentity, ensureWallet, petRow, type PetChange, type PetRow } from "./pet-state";
import { startPetLife } from "./pet-life-runner";
import { refreshPetItems } from "./pet-items";
import { serializePetRoom } from "./pet-rooms";
import { loadPlaybackPayload, readablePlayback } from "./playback";
import { selectStickerSummaries, serializeStickerSummary } from "./sticker-summaries";

/** `PetResponseV1`, typed from the serializer like every other summary-bearing response. */
export type PetResponse = {
  pet: {
    sticker: ReturnType<typeof serializeStickerSummary>;
    selectedAt: string;
    status: {
      values: Record<string, string | number | boolean>; caption: string; animateEverySeconds?: number; updatedAt: string;
    } | null;
    stats: PetStats;
    actions: PetAction[];
    items: { actions: PetAction[]; artKey: string } | null;
    identity: PetIdentityV1 | null;
    signals: PetSignalsV1 | null;
    nextEventAt: string | null;
    evolution: ReturnType<typeof serializePetEvolution>;
    weatherArt: Awaited<ReturnType<typeof serializePetWeatherArt>>;
    encounter: ReturnType<typeof serializeEncounter>;
    illness: { name: string; since: string } | null;
    medicine: number;
    room: ReturnType<typeof serializePetRoom>;
  } | null;
};

type PetStats = { happiness: number; hp: number; energy: number; gold: number };

/** What sending any sticker does on its own: a little social joy, a little effort. */
const SEND_EFFECTS = { happiness: 2, hp: 0, energy: -1 };
/** What showing the pet off in Messages does. */
const SHARE_EFFECTS = { happiness: 6, hp: 0, energy: -3 };
/** Shares closer together than this count once; showing the pet to five friends is one outing. */
const SHARE_WINDOW_MS = 10 * 60 * 1000;

/** How `ensurePetIdentity` sees a pet: its name, controls and picture. */
function describePet(db: Database, sticker: typeof stickers.$inferSelect, revision: typeof stickerRevisions.$inferSelect) {
  return async () => ({
    title: sticker.title,
    controls: revision.playbackJson?.document.configuration?.controls ?? [],
    image: await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId),
  });
}

/**
 * How long the same sticker sent again counts as the same send. A double tap, or a sticker sent to
 * three friends in a row, is one thing to react to and one model call, not three.
 */
const REPEAT_SEND_WINDOW_MS = 30_000;

/**
 * The caller's pet, or null.
 *
 * Access is re-checked on every read rather than trusted from when the pet was chosen: a pack can
 * be uninstalled or unpublished, and a sticker unpublished, after the fact. A pet that has stopped
 * being posable reads as no pet — the row is left alone, so reinstalling the pack brings it back.
 */
export async function getPet(db: Database, userId: string): Promise<PetResponse> {
  const row = await petRow(db, userId);
  if (!row) return { pet: null };
  let playback;
  try {
    playback = await readablePlayback(db, userId, row.stickerId);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return { pet: null };
    throw error;
  }
  const summary = await selectStickerSummaries(db).where(eq(stickers.id, row.stickerId)).then(firstRow);
  if (!summary) return { pet: null };
  // Pets adopted before identities get one on first read, and a life of their own.
  let pet = await ensurePetIdentity(db, row, describePet(db, playback.sticker, playback.revision));
  if (!pet.lifeRunId && pet.lifeId) await startPetLife(db, userId, pet.lifeId);
  // Today's gold, and the room's comfort, are there the moment the owner looks, not only at the
  // pet's next visit.
  const now = new Date();
  if (pet.lifeId && (dailyGold(pet.contextJson, pet.wallet, now)
    || (pet.room && roomComfortDate(pet.contextJson, pet.roomEffectDate, now)))) {
    await commitPetChange(db, userId, { lifeId: pet.lifeId, changes: [] });
    pet = await petRow(db, userId) ?? pet;
  }
  return serializePet(db, userId, pet, playback, summary);
}

async function serializePet(
  db: Database,
  userId: string,
  row: PetRow,
  playback: Awaited<ReturnType<typeof readablePlayback>>,
  summary: Parameters<typeof serializeStickerSummary>[0],
): Promise<PetResponse> {
  const status = row.statusJson && row.statusUpdatedAt
    ? { ...row.statusJson, updatedAt: row.statusUpdatedAt.toISOString() } : null;
  let actions = row.actionsJson;
  if (!actions?.length) {
    try {
      const generated = await generateActions(db, playback.sticker, playback.revision,
        { identity: row.identityJson, signals: row.signalsJson, stats: currentStats(row), ...ownerMoment(row.contextJson) });
      const updated = await db.update(userPets).set({ actionsJson: generated })
        .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, row.stickerId), isNull(userPets.actionsJson)))
        .returning({ actionsJson: userPets.actionsJson });
      actions = updated[0]?.actionsJson ?? (await db.select({ actionsJson: userPets.actionsJson }).from(userPets)
        .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, row.stickerId))).then(firstRow))?.actionsJson ?? null;
    } catch (error) {
      traceEvent("pet.actions:failed", { userId, error: describeError(error) });
    }
  }
  return { pet: { sticker: serializeStickerSummary(summary), selectedAt: row.updatedAt.toISOString(), status,
    // Actions stored before gold existed are free.
    stats: currentStats(row), actions: (actions ?? []).map((action) => ({ ...action, effects: { ...action.effects, gold: action.effects.gold ?? 0 } })),
    items: row.itemsArtKey && row.itemsJson?.length === 4
      ? { actions: row.itemsJson.map((item) => ({ ...item, effects: { ...item.effects, gold: item.effects.gold ?? 0 } })), artKey: row.itemsArtKey }
      : null,
    identity: row.identityJson, signals: row.signalsJson,
    nextEventAt: row.nextEventAt?.toISOString() ?? null, evolution: serializePetEvolution(row.evolutionJson),
    weatherArt: await serializePetWeatherArt(db, row.stickerId, row.signalsJson, playback.revision.id),
    encounter: serializeEncounter(row.lifeId ? await openEncounter(db, userId, row.lifeId) : undefined),
    illness: row.illnessJson, medicine: row.medicine, room: serializePetRoom(row) } };
}

/**
 * Adopts a sticker as the caller's pet, replacing any previous one.
 *
 * Held to the playback rule: published, controllable, and either the caller's own or a member of a
 * pack they have installed. A pet the caller could not pose would be a blank watch face.
 */
export async function setPet(db: Database, userId: string, input: SetPetRequest): Promise<PetResponse> {
  let playback;
  try {
    playback = await readablePlayback(db, userId, input.stickerId);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      throw new ApiError(404, "PET_NOT_AVAILABLE",
        "Only a published controllable sticker you made or installed can be your pet.");
    }
    throw error;
  }
  const now = new Date();
  const current = await petRow(db, userId);
  // The context is the owner's, not the pet's: it carries over to a new pet.
  const context = mergeContext(current?.contextJson ?? null, input.context, now);
  if (current?.stickerId === input.stickerId) {
    // Re-choosing the same pet keeps everything it is; only the owner's context is refreshed.
    await db.update(userPets).set({ updatedAt: now, contextJson: context }).where(eq(userPets.userId, userId));
    return getPet(db, userId);
  }

  // A new pet: born into today's world, with an identity of its own and a fresh life.
  const { signals, headlinesRefreshed } = await resolveSignals({
    context, previous: current?.signalsJson ?? null, previousAt: current?.signalsUpdatedAt ?? null, identity: null, now, userId,
  });
  const describe = describePet(db, playback.sticker, playback.revision);
  const [actions, persona] = await Promise.all([
    generateActions(db, playback.sticker, playback.revision, ownerMoment(context)),
    describe().then((pet) => getAiProvider().generatePetPersona({ petTitle: pet.title, controls: pet.controls, image: pet.image, birth: signals }))
      .catch((error) => {
        petLog("identity:fallback", { userId, stickerId: input.stickerId, error: describeError(error) });
        return null;
      }),
  ]);
  const identity = persona ? buildIdentity(persona, signals, now, petRandom) : fallbackIdentity(input.stickerId, signals, now);
  // Gold is the owner's, not the pet's: a new pet spends from the same purse as the last one.
  const petStats = withoutGold(initialStats(identity));
  await ensureWallet(db, userId, context?.timeZone);
  const stats = { ...petStats, gold: await goldBalance(db, userId) };
  const lifeId = crypto.randomUUID();
  const fresh = {
    stickerId: input.stickerId,
    updatedAt: now,
    statusJson: null,
    statusUpdatedAt: null,
    statsJson: petStats,
    interactionId: null,
    actionsJson: actions,
    itemsJson: null,
    itemsArtKey: null,
    itemsContextKey: null,
    itemsUpdatedAt: null,
    itemsClaimedAt: null,
    identityJson: identity,
    contextJson: context,
    signalsJson: signals,
    signalsUpdatedAt: headlinesRefreshed ? now : current?.signalsUpdatedAt ?? null,
    lifeId,
    lifeRunId: null,
    lifeTickAt: null,
    nextEventAt: null,
    lastShareAt: null,
    illnessJson: null,
    medicine: 0,
  };
  await db.insert(userPets).values({ userId, createdAt: now, ...fresh })
    .onConflictDoUpdate({ target: userPets.userId, set: fresh });
  await db.insert(petEvents).values({
    id: crypto.randomUUID(), userId, lifeId, stickerId: input.stickerId, kind: "adopted",
    title: `Adopted ${playback.sticker.title}`,
    detail: `A ${identity.class}: ${identity.personality}.`,
    effectsJson: ZERO_EFFECTS, statsBeforeJson: stats, statsAfterJson: stats, signalsJson: signals,
    debugJson: { identitySource: persona ? "model" : "fallback", persona, maxHp: identity.maxHp,
      energyMultiplier: identity.energyMultiplier, actions: actions.map((action) => action.title) },
    createdAt: now,
  });
  petLog("adopted", { userId, lifeId, stickerId: input.stickerId, class: identity.class, maxHp: identity.maxHp,
    energyMultiplier: identity.energyMultiplier, identitySource: persona ? "model" : "fallback" });
  await startPetLife(db, userId, lifeId);
  return getPet(db, userId);
}

/** Lets the pet go. Idempotent: clearing when there is no pet is not an error. */
export async function clearPet(db: Database, userId: string): Promise<PetResponse> {
  // The diary stays: it is keyed by life, so a later pet starts a fresh page, and a released pet's
  // history is still there to debug. The life workflow sees the row gone and ends on its next visit.
  const released = await db.delete(userPets).where(eq(userPets.userId, userId)).returning({ lifeId: userPets.lifeId });
  if (released.length) petLog("released", { userId, lifeId: released[0].lifeId });
  return { pet: null };
}

/**
 * The action takes effect only when the model returns a sentence and pose for this exact pet.
 *
 * Its effects are the action's own, plus a bonus or penalty for touching what the pet likes or
 * dislikes, with the energy cost scaled by the pet's multiplier.
 */
export async function interactWithPet(
  db: Database,
  userId: string,
  input: PetInteractionRequest,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetResponse> {
  const found = await petRow(db, userId);
  if (!found) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const { sticker, revision } = await readablePlayback(db, userId, found.stickerId);
  const pet = await ensurePetIdentity(db, found, describePet(db, sticker, revision));
  const action = [...(pet.actionsJson ?? []), ...(pet.itemsJson ?? [])]
    .find((candidate) => candidate.id === input.actionId);
  if (!action) throw new ApiError(422, "PET_ACTION_NOT_AVAILABLE", "This action is no longer available for your pet.");
  const price = -Math.min(0, action.effects.gold ?? 0);
  if (price > currentStats(pet).gold) {
    throw new ApiError(422, "PET_NOT_ENOUGH_GOLD", `This costs ${price} gold, and you have ${currentStats(pet).gold}.`);
  }
  const configuration = revision.playbackJson?.document.configuration;
  const interactionId = crypto.randomUUID();
  const claimed = await db.update(userPets).set({ interactionId })
    .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, pet.stickerId),
      pet.interactionId ? eq(userPets.interactionId, pet.interactionId) : isNull(userPets.interactionId)))
    .returning({ userId: userPets.userId });
  if (!claimed.length) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  const preference = preferenceEffects(`${action.title} ${action.description}`, pet.identityJson);
  const effects = personalizeEffects(addEffects(action.effects, preference.effects), pet.identityJson);
  const mayGrow = canEvolve(pet, sticker);
  try {
    // The next actions are chosen alongside the reply, from the mood the action leaves the pet in,
    // so the owner is offered what fits now without waiting on a second model call.
    const [answer, actions] = await Promise.all([
      getAiProvider().respondToPetInteraction({
        petTitle: sticker.title,
        action,
        stats: currentStats(pet),
        controls: configuration?.controls ?? [],
        current: pet.statusJson?.values ?? null,
        ...ownerMoment(pet.contextJson),
        canEvolve: mayGrow,
      }),
      refreshActions(db, pet, sticker, revision, {
        stats: applyEffects(currentStats(pet), effects, pet.identityJson),
        mood: `Just did “${action.title}” with its owner: ${action.description}`,
      }),
    ]);
    const values = configuration
      ? normalizedControlValues(configuration, { ...pet.statusJson?.values, ...answer.values })
      : {};
    const caption = answer.caption.trim();
    const committed = await commitPetChange(db, userId, {
      lifeId: pet.lifeId!,
      price,
      where: eq(userPets.interactionId, interactionId),
      set: { statusJson: { values, caption, animateEverySeconds: answer.animateEverySeconds, musings: answer.musings }, statusUpdatedAt: new Date(), interactionId: null,
        ...(actions ? { actionsJson: actions } : {}) },
      changes: [{
        kind: "interaction",
        title: action.title,
        detail: caption,
        effects,
        debug: { actionId: action.id, actionEffects: action.effects, preference: preference.matched,
          energyMultiplier: pet.identityJson?.energyMultiplier ?? 1, nextActions: actions?.map((next) => next.title) ?? null,
          mayGrow, evolve: answer.evolve?.brief ?? null },
      }],
    });
    if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
    if (mayGrow && answer.evolve) {
      await startPetEvolution(db, userId, { stickerId: pet.stickerId, brief: answer.evolve.brief,
        redrawWeather: answer.evolve.redrawWeather, trigger: `action: ${action.title}` });
    }
    await notify(db, userId).catch((error) => traceEvent("pet.interaction:notify:failed", { userId, error: describeError(error) }));
    return getPet(db, userId);
  } catch (error) {
    await db.update(userPets).set({ interactionId: null })
      .where(and(eq(userPets.userId, userId), eq(userPets.interactionId, interactionId)));
    throw error;
  }
}

/**
 * A sticker the caller can send: published, not deleted, and theirs or in a pack they installed —
 * the same set the Messages extension lists. Anything else is not evidence about this user.
 */
async function sendableSticker(db: Database, userId: string, stickerId: string) {
  const row = await db.select({ sticker: stickers, revision: stickerRevisions }).from(stickers)
    .innerJoin(stickerRevisions, eq(stickerRevisions.id, stickers.activeRevisionId))
    .where(and(eq(stickers.id, stickerId), eq(stickers.status, "published"), isNull(stickers.deletedAt)))
    .then(firstRow);
  if (!row) return undefined;
  if (row.sticker.ownerId === userId) return row;
  const installed = await db.select({ id: stickerPackItems.packId }).from(stickerPackItems)
    .innerJoin(stickerPacks, eq(stickerPacks.id, stickerPackItems.packId))
    .innerJoin(packInstalls, eq(packInstalls.packId, stickerPacks.id))
    .where(and(eq(stickerPackItems.stickerId, stickerId), eq(packInstalls.userId, userId),
      eq(packInstalls.state, "installed"), inArray(stickerPacks.state, ["published", "unlisted"])))
    .limit(1).then(firstRow);
  return installed ? row : undefined;
}

/**
 * Records that the caller sent a sticker, and hands back the reading to run once the response is out.
 *
 * The send is written before anything is read, so the reading can tell whether it is still the
 * latest one when it finishes. `schedule` is the route's `after`; tests pass a collector and await it.
 */
export async function recordPetSend(
  db: Database,
  userId: string,
  input: RecordPetSendRequest,
  schedule: (task: () => Promise<void>) => void,
): Promise<{ accepted: boolean }> {
  const pet = await db.select().from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
  if (!pet) return { accepted: false };
  if (!await sendableSticker(db, userId, input.stickerId)) {
    throw new ApiError(404, "STICKER_NOT_FOUND", "This sticker is not in your library.");
  }
  const now = new Date();
  if (pet.lastSentStickerId === input.stickerId && pet.lastSentAt
    && now.getTime() - pet.lastSentAt.getTime() < REPEAT_SEND_WINDOW_MS) {
    petLog("send:folded", { userId, stickerId: input.stickerId });
    return { accepted: false };
  }
  await db.update(userPets).set({ lastSentStickerId: input.stickerId, lastSentAt: now,
    contextJson: mergeContext(pet.contextJson, input.context, now) })
    .where(eq(userPets.userId, userId));
  petLog("send:recorded", { userId, stickerId: input.stickerId, withContext: !!input.context });
  schedule(() => readPetSend(db, userId, now));
  return { accepted: true };
}

/**
 * Asks the agent how the pet should look after the send recorded at `sentAt`, and stores the answer.
 *
 * The send moves the stats too: a little on its own, more with the world around it — the weather,
 * the owner's steps — plus whatever mood the model reads in the sticker. Sometimes a random event
 * happens alongside it. Each lands in the pet's diary as its own line.
 *
 * Never throws: it runs after the response, where an error has nobody to reach. A failed reading
 * leaves the pet as it was, which is what a pet that did not notice would look like anyway.
 */
export async function readPetSend(
  db: Database,
  userId: string,
  sentAt: Date,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<void> {
  try {
    const found = await petRow(db, userId);
    if (!found?.lastSentStickerId || found.lastSentAt?.getTime() !== sentAt.getTime()) return;
    const { sticker: petSticker, revision: petRevision } = await readablePlayback(db, userId, found.stickerId);
    const configuration = petRevision.playbackJson?.document.configuration;
    if (!configuration) return;
    const sent = await sendableSticker(db, userId, found.lastSentStickerId);
    if (!sent) return;
    const pet = await ensurePetIdentity(db, found, describePet(db, petSticker, petRevision));
    const identity = pet.identityJson;
    const now = new Date();
    const { signals, headlinesRefreshed } = await resolveSignals({
      context: pet.contextJson, previous: pet.signalsJson, previousAt: pet.signalsUpdatedAt, identity, now, userId,
    });
    const eventContext = { identity, signals, hour: localHour(now, pet.contextJson?.timeZone) };
    const roll = petRandom();
    const event = roll < SEND_EVENT_CHANCE ? pickEvent(eventContext, { special: false }, petRandom) : null;
    const eventDetail = event?.detail(eventContext) ?? null;

    const status = await getAiProvider().choosePetStatus({
      petTitle: petSticker.title,
      controls: configuration.controls,
      current: pet.statusJson?.values ?? null,
      identity,
      signals,
      stats: currentStats(pet),
      event: event && eventDetail ? { title: event.title, detail: eventDetail } : null,
      ...ownerMoment(pet.contextJson, now),
      sent: {
        title: sent.sticker.title,
        kind: sent.sticker.kind,
        emoji: sent.sticker.messengerEmoji,
        image: await sentStickerImage(db, sent.revision.pngAssetId ?? sent.revision.systemAssetId),
      },
    });
    // Omitted controls keep the pose the pet already had; anything the model made up falls back to
    // that control's default. The watch is only ever handed values this pet's document can play.
    const values = normalizedControlValues(configuration, { ...pet.statusJson?.values, ...status.values });
    const caption = status.caption.trim();
    const bound = (value: number) => Math.max(-8, Math.min(8, Math.round(value)));
    const mood = status.effects
      ? { happiness: bound(status.effects.happiness), hp: bound(status.effects.hp), energy: bound(status.effects.energy) }
      : ZERO_EFFECTS;
    const world = signalEffects(signals, identity);
    const changes: PetChange[] = [];
    if (event && eventDetail) {
      const preference = preferenceEffects(`${event.title} ${eventDetail}`, identity);
      changes.push({
        kind: "random",
        title: event.title,
        detail: eventDetail,
        effects: personalizeEffects(addEffects(event.effects, preference.effects), identity),
        signals,
        debug: { source: "send", eventId: event.id, eventEffects: event.effects, preference: preference.matched, roll,
          hour: eventContext.hour },
      });
    }
    changes.push({
      kind: "send",
      title: `Sent “${sent.sticker.title}”`,
      detail: caption,
      effects: personalizeEffects(addEffects(SEND_EFFECTS, world.effects, mood), identity),
      signals,
      debug: { sentStickerId: sent.sticker.id, base: SEND_EFFECTS, worldEffects: world.effects, worldReasons: world.reasons,
        moodEffects: mood, modelEffects: status.effects ?? null, roll, eventChance: SEND_EVENT_CHANCE,
        energyMultiplier: identity?.energyMultiplier ?? 1, pose: values },
    });
    const actions = await refreshActions(db, pet, petSticker, petRevision, {
      stats: changes.reduce((stats, change) => applyEffects(stats, change.effects, identity), currentStats(pet)),
      mood: `${caption} (after its owner sent “${sent.sticker.title}”${event && eventDetail ? `; also: ${event.title} — ${eventDetail}` : ""})`,
      signals,
    });
    const committed = await commitPetChange(db, userId, {
      lifeId: pet.lifeId!,
      where: and(eq(userPets.stickerId, pet.stickerId), eq(userPets.lastSentAt, sentAt)),
      set: { statusJson: { values, caption, animateEverySeconds: status.animateEverySeconds, musings: status.musings }, statusUpdatedAt: now, signalsJson: signals,
        ...(headlinesRefreshed ? { signalsUpdatedAt: now } : {}), ...(actions ? { actionsJson: actions } : {}) },
      changes,
    });
    petLog("send:read", { userId, sentStickerId: sent.sticker.id, event: event?.id ?? null, stored: !!committed });
    // The phone draws the widget and feeds the watch; wake it to fetch the pose it just missed.
    if (committed) await notify(db, userId);
  } catch (error) {
    traceEvent("pet.status:failed", { userId, error: error instanceof Error ? error.message : String(error) });
    petLog("send:failed", { userId, error: describeError(error) });
  }
}

/** What a sticker its owner made does to the pet when it cares at all: a little pride. */
const STICKER_EFFECTS = { happiness: 2, hp: 0, energy: 0 };

/** The turns that can leave a new sticker behind. Plans, exports and cleanups make nothing to look at. */
const NOTICED_JOB_KINDS = new Set(["image", "edit", "animation", "chat", "compose"]);

/**
 * Shows the owner's pet a sticker one of their turns just made, and lets the pet decide whether it
 * cares. Most stickers it lets pass; one it likes, or one that looks like a friend, gets a line, a
 * pose and a nudge to its stats, and a fresh set of actions for the mood it leaves.
 *
 * Runs as a step after the turn has completed. Never throws: the sticker is made either way, and a
 * pet that missed one is a pet that was not looking.
 */
export async function noticeNewSticker(
  db: Database,
  jobId: string,
  revisionId: string | undefined,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<void> {
  try {
    if (!revisionId) return;
    const job = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
    // The pet's own growth is announced by the pet when it is published, not noticed turn by turn.
    if (!job || job.origin !== "user" || job.state !== "succeeded" || !NOTICED_JOB_KINDS.has(job.kind)) return;
    const userId = job.ownerId;
    const found = await petRow(db, userId);
    if (!found?.lifeId || found.stickerId === job.stickerId) return;
    const made = await db.select({ sticker: stickers, revision: stickerRevisions }).from(stickerRevisions)
      .innerJoin(stickers, eq(stickers.id, stickerRevisions.stickerId))
      .where(and(eq(stickerRevisions.id, revisionId), eq(stickers.id, job.stickerId), eq(stickers.ownerId, userId)))
      .then(firstRow);
    if (!made) return;
    const { sticker: petSticker, revision: petRevision } = await readablePlayback(db, userId, found.stickerId);
    const configuration = petRevision.playbackJson?.document.configuration;
    if (!configuration) return;
    const now = new Date();
    const answer = await getAiProvider().noticePetSticker({
      petTitle: petSticker.title,
      identity: found.identityJson,
      signals: found.signalsJson,
      stats: currentStats(found),
      controls: configuration.controls,
      current: found.statusJson?.values ?? null,
      ...ownerMoment(found.contextJson, now),
      made: {
        title: made.sticker.title,
        kind: made.sticker.kind,
        image: await sentStickerImage(db, made.revision.previewAssetId ?? made.revision.masterAssetId ?? made.revision.pngAssetId),
      },
    });
    if (!answer.react) {
      petLog("sticker:ignored", { userId, stickerId: made.sticker.id, jobId });
      return;
    }
    const values = normalizedControlValues(configuration, { ...found.statusJson?.values, ...answer.values });
    const caption = answer.caption.trim();
    const bound = (value: number) => Math.max(-8, Math.min(8, Math.round(value)));
    const mood = answer.effects
      ? { happiness: bound(answer.effects.happiness), hp: bound(answer.effects.hp), energy: bound(answer.effects.energy) }
      : ZERO_EFFECTS;
    const effects = personalizeEffects(addEffects(STICKER_EFFECTS, mood), found.identityJson);
    const actions = await refreshActions(db, found, petSticker, petRevision, {
      stats: applyEffects(currentStats(found), effects, found.identityJson),
      mood: `${caption} (after its owner made a new sticker, “${made.sticker.title}”)`,
    });
    const committed = await commitPetChange(db, userId, {
      lifeId: found.lifeId,
      where: eq(userPets.stickerId, found.stickerId),
      set: { statusJson: { values, caption, animateEverySeconds: answer.animateEverySeconds, musings: answer.musings }, statusUpdatedAt: now, ...(actions ? { actionsJson: actions } : {}) },
      changes: [{
        kind: "sticker",
        title: `Saw “${made.sticker.title}”`,
        detail: caption,
        effects,
        debug: { jobId, stickerId: made.sticker.id, revisionId, base: STICKER_EFFECTS, moodEffects: mood,
          modelEffects: answer.effects ?? null, pose: values, nextActions: actions?.map((next) => next.title) ?? null },
      }],
    });
    petLog("sticker:noticed", { userId, stickerId: made.sticker.id, jobId, stored: !!committed });
    if (committed) await notify(db, userId);
  } catch (error) {
    petLog("sticker:notice-failed", { jobId, error: describeError(error) });
  }
}

/** What being shown any picture does on its own: a little attention, a little effort to look. */
const PHOTO_EFFECTS = { happiness: 2, hp: 0, energy: -1 };

/**
 * Shows the pet a picture its owner uploaded. The pet looks at it, says what it thinks, and is
 * moved by it — a little on its own, more by what the model reads in the picture — and, with its
 * mood changed, is offered a fresh set of actions. Answered in the request, like an action is.
 */
export async function sendPetPhoto(
  db: Database,
  userId: string,
  input: SendPetPhotoRequest,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetResponse> {
  const found = await petRow(db, userId);
  if (!found) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const { sticker, revision } = await readablePlayback(db, userId, found.stickerId);
  const [asset] = await getReadyOwnedAssets(db, userId, [input.assetId]);
  if (!asset.mimeType.startsWith("image/") || asset.mimeType === "image/gif") {
    throw new ApiError(422, "PET_PHOTO_NOT_IMAGE", "Your pet can only look at a still picture.");
  }
  const photo = await downscaleForModelInput((await getObjectStore().get(asset.r2Key)).bytes);
  const pet = await ensurePetIdentity(db, found, describePet(db, sticker, revision));
  const configuration = revision.playbackJson?.document.configuration;
  // The same claim an action takes, so a photo and an action cannot both answer at once.
  const interactionId = crypto.randomUUID();
  const claimed = await db.update(userPets).set({ interactionId })
    .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, pet.stickerId),
      pet.interactionId ? eq(userPets.interactionId, pet.interactionId) : isNull(userPets.interactionId)))
    .returning({ userId: userPets.userId });
  if (!claimed.length) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  const mayGrow = canEvolve(pet, sticker);
  try {
    const answer = await getAiProvider().reactToPetPhoto({
      petTitle: sticker.title,
      photo,
      identity: pet.identityJson,
      signals: pet.signalsJson,
      stats: currentStats(pet),
      controls: configuration?.controls ?? [],
      current: pet.statusJson?.values ?? null,
      ...ownerMoment(pet.contextJson),
      canEvolve: mayGrow,
    });
    const values = configuration ? normalizedControlValues(configuration, { ...pet.statusJson?.values, ...answer.values }) : {};
    const caption = answer.caption.trim();
    const bound = (value: number) => Math.max(-8, Math.min(8, Math.round(value)));
    const mood = answer.effects
      ? { happiness: bound(answer.effects.happiness), hp: bound(answer.effects.hp), energy: bound(answer.effects.energy) }
      : ZERO_EFFECTS;
    const effects = personalizeEffects(addEffects(PHOTO_EFFECTS, mood), pet.identityJson);
    const actions = await refreshActions(db, pet, sticker, revision, {
      stats: applyEffects(currentStats(pet), effects, pet.identityJson),
      mood: `${caption} (after its owner showed it a picture)`,
    });
    const committed = await commitPetChange(db, userId, {
      lifeId: pet.lifeId!,
      where: eq(userPets.interactionId, interactionId),
      set: { statusJson: { values, caption, animateEverySeconds: answer.animateEverySeconds, musings: answer.musings }, statusUpdatedAt: new Date(), interactionId: null,
        ...(actions ? { actionsJson: actions } : {}) },
      changes: [{
        kind: "photo",
        title: "Looked at a picture",
        detail: caption,
        effects,
        debug: { assetId: asset.id, base: PHOTO_EFFECTS, moodEffects: mood, modelEffects: answer.effects ?? null,
          energyMultiplier: pet.identityJson?.energyMultiplier ?? 1, nextActions: actions?.map((next) => next.title) ?? null,
          mayGrow, evolve: answer.evolve?.brief ?? null },
      }],
    });
    if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
    if (mayGrow && answer.evolve) {
      await startPetEvolution(db, userId, { stickerId: pet.stickerId, brief: answer.evolve.brief,
        redrawWeather: answer.evolve.redrawWeather, trigger: "photo" });
    }
    await notify(db, userId).catch((error) => traceEvent("pet.photo:notify:failed", { userId, error: describeError(error) }));
    return getPet(db, userId);
  } catch (error) {
    await db.update(userPets).set({ interactionId: null })
      .where(and(eq(userPets.userId, userId), eq(userPets.interactionId, interactionId)));
    throw error;
  }
}

/** Accepts a share promptly; the pet reads it after the HTTP response has been sent. */
export async function acceptPetContentShare(
  db: Database,
  userId: string,
  input: SharePetContentRequest,
  schedule: (task: () => Promise<void>) => void,
): Promise<{ accepted: true }> {
  const found = await petRow(db, userId);
  if (!found) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  await readablePlayback(db, userId, found.stickerId);
  schedule(async () => {
    try {
      await shareContentWithPet(db, userId, input);
    } catch (error) {
      petLog("content:read-failed", { userId, error: describeError(error) });
    }
  });
  return { accepted: true };
}

/** Reads an explicit share, updates the pet's pose, and keeps a diary line for its reply. */
export async function shareContentWithPet(
  db: Database,
  userId: string,
  input: SharePetContentRequest,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetResponse> {
  const found = await petRow(db, userId);
  if (!found) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const { sticker, revision } = await readablePlayback(db, userId, found.stickerId);
  const pet = await ensurePetIdentity(db, found, describePet(db, sticker, revision));
  const configuration = revision.playbackJson?.document.configuration;
  const interactionId = crypto.randomUUID();
  const claimed = await db.update(userPets).set({ interactionId })
    .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, pet.stickerId),
      pet.interactionId ? eq(userPets.interactionId, pet.interactionId) : isNull(userPets.interactionId)))
    .returning({ userId: userPets.userId });
  if (!claimed.length) throw new ApiError(409, "PET_CHANGED", "Your pet is busy. Please try again.");
  try {
    const answer = await getAiProvider().reactToPetSharedContent({
      petTitle: sticker.title,
      identity: pet.identityJson,
      title: input.title ?? null,
      url: input.url ?? null,
      content: input.content ?? null,
      html: input.html ?? null,
      stats: currentStats(pet),
      controls: configuration?.controls ?? [],
      current: pet.statusJson?.values ?? null,
      ...ownerMoment(pet.contextJson),
    });
    const values = configuration
      ? normalizedControlValues(configuration, { ...pet.statusJson?.values, ...answer.values })
      : {};
    const caption = answer.caption.trim();
    const effects = personalizeEffects({ happiness: 2, hp: 0, energy: -1, gold: 0 }, pet.identityJson);
    const actions = await refreshActions(db, pet, sticker, revision, {
      stats: applyEffects(currentStats(pet), effects, pet.identityJson),
      mood: `The owner shared ${input.title ?? input.url ?? "some content"}: ${caption}`,
    });
    const committed = await commitPetChange(db, userId, {
      lifeId: pet.lifeId!,
      where: eq(userPets.interactionId, interactionId),
      set: { statusJson: { values, caption, animateEverySeconds: answer.animateEverySeconds, musings: answer.musings },
        statusUpdatedAt: new Date(), interactionId: null, ...(actions ? { actionsJson: actions } : {}) },
      changes: [{ kind: "content", title: input.title?.slice(0, 120) || "Read a share", detail: caption,
        effects, debug: { url: input.url ?? null, contentLength: input.content?.length ?? 0, htmlLength: input.html?.length ?? 0 } }],
    });
    if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
    await notify(db, userId).catch((error) => traceEvent("pet.content:notify:failed", { userId, error: describeError(error) }));
    return getPet(db, userId);
  } catch (error) {
    await db.update(userPets).set({ interactionId: null })
      .where(and(eq(userPets.userId, userId), eq(userPets.interactionId, interactionId)));
    throw error;
  }
}

/**
 * Shows the pet off to someone in Messages. Sharing is a little outing: it cheers the pet and
 * costs some energy — once per `SHARE_WINDOW_MS`, so a pet shown in five chats is not exhausted.
 */
export async function sharePet(db: Database, userId: string): Promise<{ accepted: boolean } & PetResponse> {
  const found = await petRow(db, userId);
  if (!found) return { accepted: false, pet: null };
  const now = new Date();
  if (found.lastShareAt && now.getTime() - found.lastShareAt.getTime() < SHARE_WINDOW_MS) {
    petLog("share:folded", { userId });
    return { accepted: false, ...await getPet(db, userId) };
  }
  const { sticker, revision } = await readablePlayback(db, userId, found.stickerId).catch((error) => {
    if (error instanceof ApiError && error.status === 404) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
    throw error;
  });
  const pet = await ensurePetIdentity(db, found, describePet(db, sticker, revision));
  const preference = preferenceEffects("friends sharing showing off", pet.identityJson);
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId!,
    where: pet.lastShareAt ? eq(userPets.lastShareAt, pet.lastShareAt) : isNull(userPets.lastShareAt),
    set: { lastShareAt: now },
    changes: [{
      kind: "share",
      title: "Shown to a friend",
      detail: `${sticker.title} was shared in Messages.`,
      effects: personalizeEffects(addEffects(SHARE_EFFECTS, preference.effects), pet.identityJson),
      debug: { base: SHARE_EFFECTS, preference: preference.matched, energyMultiplier: pet.identityJson?.energyMultiplier ?? 1 },
    }],
  });
  return { accepted: !!committed, ...await getPet(db, userId) };
}

/**
 * The phone's latest context: rounded location, steps today, time zone. Stored for the life
 * workflow's next visit and the next send to read, and re-read into signals once the response is
 * out (`schedule` is the route's `after`), so a pet that was just connected to the world shows its
 * weather and steps now rather than at its next visit. Headlines stay on their own TTL.
 */
export async function updatePetContext(
  db: Database,
  userId: string,
  input: PetContextV1,
  schedule: (task: () => Promise<void>) => void = () => {},
): Promise<PetContextStoredV1> {
  const pet = await petRow(db, userId);
  if (!pet) return { stored: false, walk: null };
  const now = new Date();
  const context = mergeContext(pet.contextJson, input, now);
  await db.update(userPets).set({ contextJson: context }).where(eq(userPets.userId, userId));
  petLog("context:stored", { userId, hasLocation: context?.latitude !== undefined, stepsToday: context?.stepsToday ?? null,
    timeZone: context?.timeZone ?? null });
  // A good stretch of walking pays out as soon as the phone reports it, not at the pet's next visit,
  // and says what it paid so the phone can have the pet thank its owner for the walk right away.
  let paid: PetContextStoredV1["walk"] = null;
  const walk = walkReward({ contextJson: context, walkGoldJson: pet.wallet?.walkGoldJson ?? null }, now);
  if (isWalkPayoutDue(walk) && pet.lifeId) {
    const committed = await commitPetChange(db, userId, { lifeId: pet.lifeId, changes: [] });
    if (committed) {
      paid = {
        steps: walk.steps,
        energy: committed.after.energy - committed.before.energy,
        // The day's allowance may land in the same write; only the walk's share is the walk's.
        gold: Math.min(walk.gold, (committed.after.gold ?? 0) - (committed.before.gold ?? 0)),
      };
    }
  }
  schedule(() => refreshPetSignals(db, userId));
  return { stored: true, walk: paid };
}

/**
 * Re-reads the world for the current pet and stores it, then draws the weather it found if that
 * look is new. Never throws; it runs after the response.
 */
export async function refreshPetSignals(db: Database, userId: string): Promise<void> {
  try {
    const pet = await petRow(db, userId);
    if (!pet) return;
    const now = new Date();
    const { signals, headlinesRefreshed } = await resolveSignals({
      context: pet.contextJson, previous: pet.signalsJson, previousAt: pet.signalsUpdatedAt, identity: pet.identityJson, now, userId,
    });
    await db.update(userPets).set({ signalsJson: signals, ...(headlinesRefreshed ? { signalsUpdatedAt: now } : {}) })
      .where(and(eq(userPets.userId, userId), eq(userPets.stickerId, pet.stickerId)));
  } catch (error) {
    petLog("signals:refresh-failed", { userId, error: describeError(error) });
  }
  await drawPetWeatherArt(db, userId);
  await refreshPetItems(db, userId);
}

/** Edges the pose may be drawn at: a complication's worth up to a large widget's. */
export const PET_POSE_MIN_SIZE = 64;
export const PET_POSE_MAX_SIZE = 512;

/**
 * Bumped whenever `renderPosePng` would draw the same pose differently, so a client's cached copy
 * stops matching and the next request renders again.
 */
const POSE_RENDERER_VERSION = 1;

/**
 * The caller's pet drawn in its current pose, as a transparent PNG `size` pixels square.
 *
 * The watch and the widget cannot run the app's animation engine, so the server draws the still for
 * them. Same access rule as `getPet`: a pet that stopped being posable is no pet.
 *
 * The ETag names exactly what is drawn — revision, pose and size — so a client asking again with
 * the one it has gets `bytes: null` without anything being rendered.
 */
export async function getPetPose(
  db: Database,
  userId: string,
  size: number,
  ifNoneMatch?: string | null,
): Promise<{ etag: string; bytes: Uint8Array | null }> {
  const row = await db.select().from(userPets).where(eq(userPets.userId, userId)).then(firstRow);
  if (!row) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
  let revision: Awaited<ReturnType<typeof readablePlayback>>["revision"];
  try {
    ({ revision } = await readablePlayback(db, userId, row.stickerId));
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
    }
    throw error;
  }
  const values = row.statusJson?.values ?? {};
  const etag = `"${createHash("sha256")
    .update(canonicalJson({ revision: revision.id, values, size, renderer: POSE_RENDERER_VERSION }))
    .digest("hex").slice(0, 32)}"`;
  if (ifNoneMatch?.split(",").some((candidate) => candidate.trim() === etag)) return { etag, bytes: null };

  const { document, rows } = await loadPlaybackPayload(db, row.stickerId, revision);
  const store = getObjectStore();
  const assetBytes: RenderAssets = new Map();
  await Promise.all(rows.map(async (asset) => {
    try {
      assetBytes.set(asset.id, { bytes: (await store.get(asset.r2Key)).bytes, mimeType: asset.mimeType });
    } catch (error) {
      // Drawn as the renderer's placeholder rather than refused: a pet with one missing layer is
      // still the user's pet, and the next publish of the sticker repairs it.
      traceEvent("pet.pose:asset:unreadable", { assetId: asset.id, error: describeError(error) });
    }
  }));
  const bytes = await renderPosePng(resolveStickerConfiguration(document, values), assetBytes, size);
  return { etag, bytes };
}
