import { and, desc, eq, gt, gte, isNotNull, sql } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { ResolvePetEncounterRequest } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { petEncounters, stickers, userPets, type PetEncounterChoice, type PetEncounterRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetEncounter, notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError } from "@/lib/observability/trace";
import { ENCOUNTER_LIFETIME_MS, encounterDueDate, sanitizeChoice } from "@/lib/pets/encounters";
import { catchIllness, MEDICINE_EFFECTS } from "@/lib/pets/illness";
import { petLog, petRandom } from "@/lib/pets/log";
import { personalizeEffects, ZERO_EFFECTS, type PetEffects } from "@/lib/pets/stats";
import { ownerMoment } from "./pet-actions";
import { commitPetChange, currentStats, petRow, type PetChange } from "./pet-state";

/** How many earlier encounters the agent is shown, so a new day brings something new. */
const PREVIOUS_ENCOUNTERS = 7;

type Notify = (db: Database, userId: string, encounter: { id: string; title: string; prompt: string }) => Promise<void>;

/**
 * Writes today's encounter if one is due and the pet has not had one today, then tells the owner.
 * Run on every life-workflow visit; most of them find nothing to do. Never throws: a day the agent
 * could not write one is a quiet day, and the next visit tries again.
 */
export async function maybeStartEncounter(
  db: Database,
  userId: string,
  now = new Date(),
  notify: Notify = notifyPetEncounter,
): Promise<PetEncounterRow | null> {
  try {
    const pet = await petRow(db, userId);
    if (!pet?.lifeId) return null;
    const date = encounterDueDate(userId, pet.lifeId, now, pet.contextJson?.timeZone);
    if (!date) return null;
    const earlier = await db.select({ date: petEncounters.date, title: petEncounters.title }).from(petEncounters)
      .where(and(eq(petEncounters.userId, userId), eq(petEncounters.lifeId, pet.lifeId)))
      .orderBy(desc(petEncounters.createdAt))
      .limit(PREVIOUS_ENCOUNTERS);
    if (earlier.some((encounter) => encounter.date === date)) return null;

    const written = await getAiProvider().generatePetEncounter({
      petTitle: (await petTitle(db, pet.stickerId)) ?? "Pet",
      identity: pet.identityJson,
      signals: pet.signalsJson,
      stats: currentStats(pet),
      illness: pet.illnessJson?.name ?? null,
      mood: pet.statusJson?.caption ?? null,
      previous: earlier.map((encounter) => encounter.title),
      ...ownerMoment(pet.contextJson, now),
    });
    const choices: PetEncounterChoice[] = written.choices
      .map((choice) => ({ id: crypto.randomUUID(), ...sanitizeChoice(choice) }));
    if (!choices.some((choice) => choice.correct) || choices.every((choice) => choice.correct)) {
      throw new Error("Encounter needs both a right and a wrong choice");
    }
    // Shuffled, so the right answer does not always sit where the agent happened to put it.
    for (let index = choices.length - 1; index > 0; index -= 1) {
      const swap = Math.floor(petRandom() * (index + 1)) % (index + 1);
      [choices[index], choices[swap]] = [choices[swap], choices[index]];
    }
    const [inserted] = await db.insert(petEncounters).values({
      id: crypto.randomUUID(),
      userId,
      lifeId: pet.lifeId,
      date,
      title: written.title.slice(0, 60),
      prompt: written.prompt.slice(0, 240),
      choicesJson: choices,
      state: "open",
      expiresAt: new Date(now.getTime() + ENCOUNTER_LIFETIME_MS),
      createdAt: now,
    }).onConflictDoNothing().returning();
    if (!inserted) return null;
    petLog("encounter:started", { userId, lifeId: pet.lifeId, id: inserted.id, title: inserted.title, date,
      correct: choices.filter((choice) => choice.correct).map((choice) => choice.title) });
    await notify(db, userId, inserted);
    return inserted;
  } catch (error) {
    petLog("encounter:start-failed", { userId, error: describeError(error) });
    return null;
  }
}

async function petTitle(db: Database, stickerId: string): Promise<string | undefined> {
  return (await db.select({ title: stickers.title }).from(stickers).where(eq(stickers.id, stickerId)).then(firstRow))?.title;
}

/** The encounter still waiting on the owner for this life, or undefined. */
export async function openEncounter(db: Database, userId: string, lifeId: string, now = new Date()): Promise<PetEncounterRow | undefined> {
  return db.select().from(petEncounters)
    .where(and(eq(petEncounters.userId, userId), eq(petEncounters.lifeId, lifeId),
      eq(petEncounters.state, "open"), gt(petEncounters.expiresAt, now)))
    .orderBy(desc(petEncounters.createdAt))
    .limit(1)
    .then(firstRow);
}

/** The encounter as the client sees it: the choices, never which is right or what they lead to. */
export function serializeEncounter(row: PetEncounterRow | undefined) {
  if (!row) return null;
  return {
    id: row.id,
    title: row.title,
    prompt: row.prompt,
    choices: row.choicesJson.map((choice) => ({ id: choice.id, title: choice.title, description: choice.description })),
    expiresAt: row.expiresAt.toISOString(),
  };
}

export type PetEncounterOutcome = {
  choiceId: string;
  correct: boolean;
  text: string;
  effects: Required<PetEffects>;
  medicine: number;
  sickened: boolean;
};

/**
 * The owner's pick for an open encounter. Claimed first, so a double tap resolves it once; then the
 * outcome lands on the pet — stats, any medicine won, an illness a wrong pick brought on — and the
 * pet says what happened. A pick that cannot land reopens the encounter.
 */
export async function resolvePetEncounter(
  db: Database,
  userId: string,
  input: ResolvePetEncounterRequest,
  now = new Date(),
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetEncounterOutcome> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const encounter = await db.select().from(petEncounters)
    .where(and(eq(petEncounters.id, input.encounterId), eq(petEncounters.userId, userId), eq(petEncounters.lifeId, pet.lifeId)))
    .then(firstRow);
  if (!encounter) throw new ApiError(404, "PET_ENCOUNTER_NOT_FOUND", "This moment has passed.");
  const choice = encounter.choicesJson.find((candidate) => candidate.id === input.choiceId);
  if (!choice) throw new ApiError(422, "PET_ENCOUNTER_CHOICE_INVALID", "That isn't one of the choices.");
  const [claimed] = await db.update(petEncounters).set({ state: "resolved", choiceId: choice.id, resolvedAt: now })
    .where(and(eq(petEncounters.id, encounter.id), eq(petEncounters.state, "open"), gt(petEncounters.expiresAt, now)))
    .returning({ id: petEncounters.id });
  if (!claimed) {
    throw encounter.state === "resolved"
      ? new ApiError(409, "PET_ENCOUNTER_RESOLVED", "You already decided this one.")
      : new ApiError(410, "PET_ENCOUNTER_EXPIRED", "This moment has passed.");
  }

  const effects = personalizeEffects(choice.effects, pet.identityJson);
  const sickened = choice.sickens && !pet.illnessJson;
  const illness = sickened ? catchIllness(now, petRandom) : null;
  const changes: PetChange[] = [{
    kind: "encounter",
    title: encounter.title,
    detail: `Chose “${choice.title}” — ${choice.correct ? "the right call" : "not the right call"}. “${choice.outcome}”`,
    effects,
    debug: { encounterId: encounter.id, choiceId: choice.id, correct: choice.correct, choiceEffects: choice.effects,
      medicine: choice.medicine, sickens: choice.sickens, energyMultiplier: pet.identityJson?.energyMultiplier ?? 1 },
  }];
  if (illness) {
    changes.push({ kind: "illness", title: "Fell ill", detail: `Came down with ${illness.name}.`, effects: ZERO_EFFECTS,
      debug: { source: "encounter", encounterId: encounter.id } });
  }
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId,
    set: {
      ...(choice.medicine > 0 ? { medicine: sql`${userPets.medicine} + ${choice.medicine}` } : {}),
      ...(illness ? { illnessJson: illness } : {}),
      // The pet says how it went; the queued musings were about before, so they go.
      ...(pet.statusJson ? { statusJson: { ...pet.statusJson, caption: choice.outcome, musings: undefined }, statusUpdatedAt: now } : {}),
    },
    changes,
  });
  if (!committed) {
    await db.update(petEncounters).set({ state: "open", choiceId: null, resolvedAt: null })
      .where(eq(petEncounters.id, encounter.id));
    throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  }
  petLog("encounter:resolved", { userId, lifeId: pet.lifeId, id: encounter.id, correct: choice.correct, effects,
    medicine: choice.medicine, sickened });
  await notify(db, userId).catch((error) => petLog("encounter:notify-failed", { userId, error: describeError(error) }));
  return {
    choiceId: choice.id,
    correct: choice.correct,
    text: choice.outcome,
    effects: { ...effects, gold: effects.gold ?? 0 },
    medicine: choice.medicine,
    sickened,
  };
}

/** Gives the ill pet a dose of medicine: it is cured at once, and perks up. */
export async function givePetMedicine(
  db: Database,
  userId: string,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<void> {
  const pet = await petRow(db, userId);
  if (!pet?.lifeId) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  if (!pet.illnessJson) throw new ApiError(422, "PET_NOT_ILL", "Your pet is well and doesn't need medicine.");
  if (pet.medicine < 1) throw new ApiError(422, "PET_NO_MEDICINE", "Your pet has no medicine. Buy some in the item shop, or help it with its daily events to earn some.");
  const illness = pet.illnessJson;
  const committed = await commitPetChange(db, userId, {
    lifeId: pet.lifeId,
    where: and(gte(userPets.medicine, 1), isNotNull(userPets.illnessJson)),
    set: { medicine: sql`${userPets.medicine} - 1`, illnessJson: null },
    changes: [{ kind: "medicine", title: "Took medicine", detail: `Cured of ${illness.name}.`,
      effects: MEDICINE_EFFECTS, debug: { illness, medicineBefore: pet.medicine } }],
  });
  if (!committed) throw new ApiError(409, "PET_CHANGED", "Your pet changed. Please try again.");
  petLog("medicine:given", { userId, lifeId: pet.lifeId, illness: illness.name });
  await notify(db, userId).catch((error) => petLog("medicine:notify-failed", { userId, error: describeError(error) }));
}
