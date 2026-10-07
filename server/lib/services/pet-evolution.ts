// The pet growing on its own: a new mood, property or look added to its sticker in the background.
//
// The pet's agent decides when — answering an action or a picture, it may ask to grow — and this
// file does the rest without the owner in the loop: a planning turn on the pet's sticker, the plan
// confirmed, built and published, then the pet tells its owner what it learned. Each stage is a
// durable step of `workflows/pet-evolution`; the logic and the tests live here.
//
// Growth is free to the owner (the jobs carry no credit hold and spend no daily allowance), so it
// is held to one per cooldown, and only a sticker the owner made can grow: a pack sticker is
// someone else's artwork.

import { and, desc, eq, inArray, isNull, lt, or } from "drizzle-orm";
import { start } from "workflow/api";
import { getAiProvider } from "@/lib/ai/gateway";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, generationJobs, plans, stickers, userPets, type PetEvolution, type PetMusing, type UserPetRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetEvolved } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { ACTIVE_EVOLUTION_STATES, EVOLUTION_STALE_AFTER_MS, evolutionInFlight } from "@/lib/pets/evolution";
import { petLog } from "@/lib/pets/log";
import { EMPTY_SIGNALS } from "@/lib/pets/signals";
import { applyEffects, personalizeEffects } from "@/lib/pets/stats";
import { petEvolutionWorkflow } from "@/workflows/pet-evolution";
import { ownerMoment, refreshActions } from "./pet-actions";
import { commitPetChange, currentStats, petRow } from "./pet-state";
import { confirmPlan } from "./plans";
import { lastPublishedPlayback } from "./playback";
import { quickPublishSticker } from "./quick-publish";
import { forgetPetWeatherArt } from "./pet-weather";
import { createChatTurn } from "./sticker-chat";
import { startGenerationWorkflow } from "./workflows";

/** What growing does to the pet on its own: pride, and the effort of it. */
const EVOLVED_EFFECTS = { happiness: 10, hp: 0, energy: -5 };

function cooldownMs(): number {
  const hours = Number(process.env.PET_EVOLUTION_COOLDOWN_HOURS ?? 24);
  return (Number.isFinite(hours) && hours >= 0 ? hours : 24) * 60 * 60 * 1000;
}

function evolutionEnabled(): boolean {
  return process.env.PET_EVOLUTION_ENABLED !== "false";
}

/** The earliest `lastEvolvedAt` that still blocks a new evolution: the cooldown, or a run still going. */
function blockingSince(now: Date): Date {
  return new Date(now.getTime() - Math.max(cooldownMs(), EVOLUTION_STALE_AFTER_MS));
}

/**
 * Whether the pet may be offered growth right now. The answer is only an offer: `startPetEvolution`
 * claims the row again, so two moments that both said yes still grow the pet once.
 */
export function canEvolve(pet: UserPetRow, sticker: typeof stickers.$inferSelect, now = new Date()): boolean {
  if (!evolutionEnabled()) return false;
  if (sticker.ownerId !== pet.userId || !sticker.controllable || sticker.kind !== "animated") return false;
  return !pet.lastEvolvedAt || pet.lastEvolvedAt < blockingSince(now);
}

type EvolutionStarter = (userId: string, evolutionId: string) => Promise<string>;
let starterForTests: EvolutionStarter | undefined;

/** Tests run no workflow runtime; they install a starter to see what would have been started. */
export function setPetEvolutionStarterForTests(starter: EvolutionStarter | undefined): void {
  starterForTests = starter;
}

/**
 * Claims the pet's next evolution and starts the workflow that grows it. False when the pet may not
 * grow now — the cooldown, a run already going, or a pet that changed. Never throws: the moment that
 * asked for it has already been answered.
 */
export async function startPetEvolution(
  db: Database,
  userId: string,
  input: { stickerId: string; brief: string; trigger: string; redrawWeather?: boolean },
  now = new Date(),
): Promise<boolean> {
  const evolution: PetEvolution = {
    id: crypto.randomUUID(),
    state: "planning",
    brief: input.brief,
    trigger: input.trigger,
    stickerId: input.stickerId,
    startedAt: now.toISOString(),
    ...(input.redrawWeather ? { redrawWeather: true } : {}),
  };
  try {
    const claimed = await db.update(userPets).set({ evolutionJson: evolution, lastEvolvedAt: now })
      .where(and(
        eq(userPets.userId, userId),
        eq(userPets.stickerId, input.stickerId),
        or(isNull(userPets.lastEvolvedAt), lt(userPets.lastEvolvedAt, blockingSince(now))),
      ))
      .returning({ userId: userPets.userId });
    if (!claimed.length) {
      petLog("evolution:not-claimed", { userId, trigger: input.trigger });
      return false;
    }
    let runId: string;
    if (starterForTests) runId = await starterForTests(userId, evolution.id);
    else if (process.env.NODE_ENV === "test") runId = "test-skipped";
    else runId = (await start(petEvolutionWorkflow, [userId, evolution.id])).runId;
    petLog("evolution:started", { userId, evolutionId: evolution.id, trigger: input.trigger, brief: input.brief, runId });
    return true;
  } catch (error) {
    petLog("evolution:start-failed", { userId, error: describeError(error) });
    await failPetEvolution(db, userId, evolution.id, describeError(error)).catch(() => undefined);
    return false;
  }
}

/** The pet's row, only while it is still growing `evolutionId`; otherwise the run has nothing to do. */
async function evolvingPet(db: Database, userId: string, evolutionId: string) {
  const pet = await petRow(db, userId);
  const evolution = pet?.evolutionJson;
  if (!pet || evolution?.id !== evolutionId || pet.stickerId !== evolution.stickerId) return undefined;
  if (!ACTIVE_EVOLUTION_STATES.includes(evolution.state)) return undefined;
  return { pet, evolution };
}

async function updateEvolution(db: Database, userId: string, evolutionId: string, patch: Partial<PetEvolution>): Promise<void> {
  const pet = await petRow(db, userId);
  if (pet?.evolutionJson?.id !== evolutionId) return;
  await db.update(userPets).set({ evolutionJson: { ...pet.evolutionJson, ...patch } }).where(eq(userPets.userId, userId));
}

/**
 * The brief as the planner reads it: the pet's own words, and how the addition must be built.
 *
 * Left to itself the planner paints the new item into the character's still and redraws it on top,
 * which hides the pet behind its own prize and gives the owner nothing to switch. So the item is
 * always its own layer beside the character, shown by a toggle, with a new pose to go with it.
 */
export function planningInstruction(brief: string): string {
  return [
    `My pet asked to grow: ${brief}`,
    "Extend this sticker with exactly that one addition, built like this:",
    "1. Draw the new item as its own separate accessory layer, never painted into or over the character.",
    "Place it beside the character — at its side, by its paws or floating just off its shoulder — at about a",
    "quarter of the character's size, so the two boxes do not overlap and the item never covers the",
    "character's face or body. Keep both fully on the canvas, shrinking or shifting the character a little",
    "if it needs the room.",
    "2. Make the item controllable: add a toggle control that binds the item layer's visibility, on by",
    "default, labelled with the item's name.",
    "3. Give the item a gentle motion of its own (a bob, a sway or a slow float), and add one new pose clip to",
    "the character's sprite in which it plays with, looks at or reaches toward the item, as a new option on",
    "its existing pose control.",
    "Keep the character, its existing clips, expressions, controls, option ids and look exactly as they are,",
    "and add only what the addition needs.",
  ].join(" ");
}

/**
 * Stage one: a planning turn on the pet's sticker, from the pet's brief. Returns the planning job.
 * A replayed step finds the job its first attempt queued instead of queueing a second.
 */
export async function beginPetEvolutionPlan(db: Database, userId: string, evolutionId: string): Promise<string | null> {
  const current = await evolvingPet(db, userId, evolutionId);
  if (!current) return null;
  if (current.evolution.planJobId) return current.evolution.planJobId;
  let jobId: string;
  try {
    ({ jobId } = await createChatTurn(db, userId, current.evolution.stickerId, {
      text: planningInstruction(current.evolution.brief),
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    }, false, false, "pet"));
  } catch (error) {
    // The first attempt queued the job and died before saying so. Anything else is a real refusal.
    if (!(error instanceof ApiError && error.code === "AI_TURN_IN_PROGRESS")) throw error;
    const running = await db.select({ id: generationJobs.id }).from(generationJobs)
      .where(and(eq(generationJobs.stickerId, current.evolution.stickerId), eq(generationJobs.origin, "pet"),
        eq(generationJobs.kind, "plan"), inArray(generationJobs.state, ["queued", "running", "waiting"])))
      .orderBy(desc(generationJobs.createdAt)).limit(1).then(firstRow);
    if (!running) throw error;
    jobId = running.id;
  }
  await updateEvolution(db, userId, evolutionId, { planJobId: jobId });
  if (!(await db.select({ runId: generationJobs.workflowRunId }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.runId) {
    await startGenerationWorkflow(db, jobId);
  }
  return jobId;
}

/** A job's state, for the workflow to wait on. */
export async function petEvolutionJobState(db: Database, jobId: string): Promise<string | null> {
  return (await db.select({ state: generationJobs.state }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.state ?? null;
}

/** Stage two: confirm the plan the planning turn finalized, and start building it. */
export async function confirmPetEvolutionPlan(db: Database, userId: string, evolutionId: string): Promise<string | null> {
  const current = await evolvingPet(db, userId, evolutionId);
  if (!current?.evolution.planJobId) return null;
  if (current.evolution.composeJobId) return current.evolution.composeJobId;
  const card = await db.select({ planId: chatMessages.planId }).from(chatMessages)
    .where(and(eq(chatMessages.jobId, current.evolution.planJobId), eq(chatMessages.role, "assistant"), eq(chatMessages.kind, "plan")))
    .limit(1).then(firstRow);
  if (!card?.planId) throw new Error("The evolution's planning turn left no plan");
  const plan = await db.select().from(plans).where(eq(plans.id, card.planId)).then(firstRow);
  let jobId: string;
  if (plan?.state === "confirmed" && plan.jobId) {
    jobId = plan.jobId;
  } else {
    ({ jobId } = await confirmPlan(db, userId, current.evolution.stickerId, card.planId, 6, "pet"));
  }
  await updateEvolution(db, userId, evolutionId, { composeJobId: jobId, state: "building" });
  if (!(await db.select({ runId: generationJobs.workflowRunId }).from(generationJobs)
    .where(eq(generationJobs.id, jobId)).then(firstRow))?.runId) {
    await startGenerationWorkflow(db, jobId);
  }
  return jobId;
}

/**
 * Stage three: accept the built revision and publish it, so the pet's playback — what the watch,
 * the widget and the Pet tab draw — becomes the grown one.
 */
export async function publishPetEvolution(db: Database, userId: string, evolutionId: string): Promise<boolean> {
  const current = await evolvingPet(db, userId, evolutionId);
  if (!current?.evolution.composeJobId) return false;
  const { stickerId, composeJobId } = current.evolution;
  await updateEvolution(db, userId, evolutionId, { state: "publishing" });
  const before = await db.select({ activeRevisionId: stickers.activeRevisionId, status: stickers.status })
    .from(stickers).where(eq(stickers.id, stickerId)).then(firstRow);
  try {
    // The build's candidate carries the build job's id. Publishing it by name rather than taking the
    // newest candidate keeps a revision the owner happened to be drafting out of the pet. It is
    // rendered before it is accepted, so the old look stays published — and the pet on screen —
    // for the whole render instead of the sticker sitting as a draft and the pet disappearing.
    await quickPublishSticker(db, userId, stickerId, undefined, { candidateId: composeJobId, acceptLast: true });
  } catch (error) {
    // Accepting made the unpublished build the active revision, which leaves the sticker a draft and
    // the pet with nothing to play. Put the published look back; the build stays in the sticker's
    // history for the owner to publish from the app.
    if (before?.activeRevisionId && before.status === "published") {
      await db.update(stickers).set({ activeRevisionId: before.activeRevisionId, status: "published", updatedAt: new Date() })
        .where(and(eq(stickers.id, stickerId), eq(stickers.activeRevisionId, composeJobId), eq(stickers.status, "draft")));
    }
    throw error;
  }
  return true;
}

/**
 * Stage four: the pet, in its new look, says what it learned. The line becomes its caption, a
 * diary entry and a notification; its actions are chosen again against the new controls.
 */
export async function finishPetEvolution(
  db: Database,
  userId: string,
  evolutionId: string,
  notify: (db: Database, userId: string, alert: { title: string; body: string }) => Promise<void> = notifyPetEvolved,
): Promise<boolean> {
  const current = await evolvingPet(db, userId, evolutionId);
  if (!current) return false;
  const { pet, evolution } = current;
  const { sticker, revision } = await lastPublishedPlayback(db, userId, pet.stickerId);
  const configuration = revision.playbackJson?.document.configuration;
  const plan = evolution.composeJobId
    ? await db.select({ planJson: plans.planJson }).from(plans).where(eq(plans.jobId, evolution.composeJobId)).then(firstRow)
    : undefined;
  const learned = plan?.planJson.summary ?? evolution.brief;
  const now = new Date();
  let caption = `I learned something new!`;
  let values = pet.statusJson?.values ?? {};
  let animateEverySeconds = pet.statusJson?.animateEverySeconds;
  // The old lines followed the old caption; the event's narration brings its own or none.
  let musings: PetMusing[] | undefined;
  try {
    const answer = await getAiProvider().narratePetEvent({
      petTitle: sticker.title,
      identity: pet.identityJson,
      signals: pet.signalsJson ?? EMPTY_SIGNALS,
      event: { title: "Grew something new", detail: `You just grew: ${learned}. Show it off.` },
      stats: currentStats(pet),
      controls: configuration?.controls ?? [],
      current: pet.statusJson?.values ?? null,
      ...ownerMoment(pet.contextJson, now),
    });
    caption = answer.caption.trim() || caption;
    values = { ...values, ...answer.values };
    animateEverySeconds = answer.animateEverySeconds ?? animateEverySeconds;
    musings = answer.musings;
  } catch (error) {
    petLog("evolution:narrate-failed", { userId, evolutionId, error: describeError(error) });
  }
  values = configuration ? normalizedControlValues(configuration, values) : {};
  const effects = personalizeEffects(EVOLVED_EFFECTS, pet.identityJson);
  const actions = await refreshActions(db, pet, sticker, revision, {
    stats: applyEffects(currentStats(pet), effects, pet.identityJson),
    mood: `${caption} (it just grew: ${learned})`,
  });
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId!,
    set: {
      statusJson: { values, caption, animateEverySeconds, musings }, statusUpdatedAt: now,
      evolutionJson: { ...evolution, state: "ready", finishedAt: now.toISOString() },
      ...(actions ? { actionsJson: actions } : {}),
    },
    changes: [{
      kind: "evolved",
      title: "Grew something new",
      detail: caption,
      effects,
      debug: { evolutionId, brief: evolution.brief, trigger: evolution.trigger, learned, revisionId: revision.id,
        planJobId: evolution.planJobId, composeJobId: evolution.composeJobId, nextActions: actions?.map((next) => next.title) ?? null },
    }],
  });
  petLog("evolution:finished", { userId, evolutionId, stored: !!committed, redrawWeather: !!evolution.redrawWeather });
  // The weather belongs to the sticker and survives a growth; only a pet that changed its whole look
  // asked for it to be drawn again.
  if (committed && evolution.redrawWeather) {
    await forgetPetWeatherArt(db, pet.stickerId)
      .catch((error) => petLog("evolution:weather-forget-failed", { userId, evolutionId, error: describeError(error) }));
  }
  if (committed) await notify(db, userId, { title: `${sticker.title} grew!`, body: caption });
  return !!committed;
}

/** Ends an evolution that could not finish. The pet stays as it was; the cooldown still holds. */
export async function failPetEvolution(db: Database, userId: string, evolutionId: string, message: string): Promise<void> {
  const pet = await petRow(db, userId);
  if (pet?.evolutionJson?.id !== evolutionId || !ACTIVE_EVOLUTION_STATES.includes(pet.evolutionJson.state)) return;
  await db.update(userPets).set({
    evolutionJson: { ...pet.evolutionJson, state: "failed", finishedAt: new Date().toISOString(), error: message.slice(0, 300) },
  }).where(eq(userPets.userId, userId));
  petLog("evolution:failed", { userId, evolutionId, error: message.slice(0, 300) });
}

/** The public shape of `PetEvolution`: where it is, never the brief or the jobs behind it. */
export function serializePetEvolution(evolution: PetEvolution | null) {
  if (!evolution) return null;
  const stale = ACTIVE_EVOLUTION_STATES.includes(evolution.state) && !evolutionInFlight(evolution);
  return {
    state: stale ? "failed" as const : evolution.state,
    startedAt: evolution.startedAt,
    finishedAt: evolution.finishedAt ?? null,
  };
}
