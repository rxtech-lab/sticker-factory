import { getAiProvider } from "@/lib/ai/gateway";
import type { AiPetDecisionAnswer, AiPetDecisionQuestion } from "@/lib/ai/gateway-contracts";
import type { PetIdentityV1 } from "@/lib/contracts/api";
import { normalizedControlValues, type StickerConfiguration, type StickerControl } from "@/lib/contracts/configuration";
import { and, eq, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { describeCondition } from "@/lib/pets/condition";
import { petLog } from "@/lib/pets/log";
import { currentStats, type PetRow } from "./pet-state";

// The pet is a controllable sticker, and which controls it has differs from pet to pet. Its pose is
// picked by the decision model rather than written by the pet's agent: one typed question per control,
// answered only with values that sticker can draw.

type ControlValues = Record<string, string | number | boolean>;
type PosableControl = Extract<StickerControl, { type: "choice" | "toggle" }>;
type DecisionAnswers = Record<string, AiPetDecisionAnswer>;

/** Who is being posed, and what just happened to it. */
export type PetPoseMoment = {
  petTitle: string;
  identity: PetIdentityV1 | null;
  stats: { happiness: number; energy: number; hp: number };
  /** The illness it has caught, when it is ill. */
  illness?: string | null;
  /** What just happened, from the pet's side: "Its owner just tapped it gently." */
  moment: string;
  /** What the pet said back, when it already has. */
  said?: string | null;
};

/** The controls a pose may change: every choice and toggle. Speed is left to the pet's agent. */
export function posableControls(controls: readonly StickerControl[]): PosableControl[] {
  return controls.filter((control): control is PosableControl => control.type !== "number");
}

/**
 * One question per control in `controls`: what the pet switches to, given it holds `current`. Every
 * interaction moves the pet, so a choice is asked only among the options it does not hold now; a
 * toggle is asked plainly and may stay as it is.
 */
export function poseQuestions(controls: readonly PosableControl[], current: ControlValues): Record<string, AiPetDecisionQuestion> {
  return Object.fromEntries(controls.map((control): [string, AiPetDecisionQuestion] => {
    if (control.type === "choice") {
      const now = control.options.find((option) => option.id === current[control.id]) ?? control.options.find((option) => option.id === control.defaultValue);
      const others = control.options.filter((option) => option.id !== now?.id);
      return [control.id, {
        type: "choice",
        instructions: `The pet's "${control.label}" is "${now?.label ?? control.defaultValue}" now and switches. Which "${control.label}" best shows how it feels right now — its condition (how tired, happy or unwell it is) as much as the moment?`,
        criteria: Object.fromEntries((others.length ? others : control.options).map((option) => [option.id, option.label])),
      }];
    }
    return [control.id, {
      type: "boolean",
      instructions: `Does the pet have "${control.label}" on, given its condition and the moment?`,
      criteria: { true: `${control.label} on`, false: `${control.label} off` },
    }];
  }));
}

/** The pose in `answers`. Answers the sticker cannot draw are left out. */
export function poseValues(controls: readonly PosableControl[], answers: DecisionAnswers): Record<string, string | boolean> {
  const values: Record<string, string | boolean> = {};
  for (const control of controls) {
    const answer = answers[control.id];
    if (control.type === "choice" && answer?.type === "choice" && control.options.some((option) => option.id === answer.choice)) {
      values[control.id] = answer.choice;
    } else if (control.type === "toggle" && answer?.type === "boolean") {
      values[control.id] = answer.probability >= 0.5;
    }
  }
  return values;
}

function describePosedPet(input: PetPoseMoment) {
  const maxHp = input.identity?.maxHp ?? 100;
  return {
    pet: input.petTitle,
    ...(input.identity ? { class: input.identity.class, personality: input.identity.personality,
      likes: input.identity.likes, dislikes: input.identity.dislikes } : {}),
    feels: describeCondition(input.stats, maxHp, input.illness),
    happiness: `${input.stats.happiness}/100`,
    energy: `${input.stats.energy}/100`,
    hp: `${input.stats.hp}/${maxHp}`,
    moment: input.moment,
    ...(input.said ? { petSaid: input.said } : {}),
  };
}

/** Each answer on one line for the logs: the pick, then how likely each option was. */
function describeAnswers(answers: DecisionAnswers): Record<string, string> {
  return Object.fromEntries(Object.entries(answers).map(([id, answer]) => {
    if (answer.type === "boolean") return [id, `true ${answer.probability.toFixed(2)}`];
    const odds = Object.entries(answer.probabilities ?? {}).sort(([, a], [, b]) => b - a)
      .map(([option, probability]) => `${option} ${probability.toFixed(2)}`).join(", ");
    return [id, answer.type === "choice" ? `${answer.choice} (${odds})` : `${answer.score.toFixed(2)} (${odds})`];
  }));
}

/**
 * The pose the decision model strikes for `input` from `configuration`'s controls, against the pose
 * the pet holds now. Null when there is nothing to pose or the model does not answer in time.
 */
export async function decidePetPose(
  configuration: StickerConfiguration,
  current: ControlValues,
  input: PetPoseMoment,
  timeoutMs = 5_000,
): Promise<Record<string, string | boolean> | null> {
  const controls = posableControls(configuration.controls);
  if (!controls.length) return null;
  const startedAt = Date.now();
  try {
    const answers = await getAiProvider().decideForPet(describePosedPet(input), poseQuestions(controls, current), timeoutMs);
    const pose = poseValues(controls, answers);
    petLog("pose:decided", { pet: input.petTitle, moment: input.moment,
      feels: describeCondition(input.stats, input.identity?.maxHp ?? 100, input.illness), ms: Date.now() - startedAt, current, answers: describeAnswers(answers), pose });
    return pose;
  } catch (error) {
    petLog("pose:decision-failed", { pet: input.petTitle, moment: input.moment, ms: Date.now() - startedAt, error: describeError(error) });
    return null;
  }
}

/**
 * The pose the pet holds after a user interaction: its decision model's, laid over what its agent
 * chose (`agentValues`, which still sets speed, and stands in whole when the decision model fails),
 * laid over the pose it held before. Only values `configuration` can play.
 */
export async function posePetForInteraction(
  configuration: StickerConfiguration,
  held: ControlValues | null | undefined,
  agentValues: ControlValues,
  input: PetPoseMoment,
): Promise<ControlValues> {
  const current = normalizedControlValues(configuration, held ?? {});
  const decided = await decidePetPose(configuration, current, input);
  const pose = normalizedControlValues(configuration, { ...held, ...agentValues, ...decided });
  petLog("pose:interaction", { pet: input.petTitle, moment: input.moment, agent: agentValues, decided, pose });
  return pose;
}

/** The pet's pose at rest only answers quickly or not at all: someone is waiting to see it. */
const RESTING_DECISION_TIMEOUT_MS = 3_000;

/**
 * Keeps the pose the pet holds between interactions — the one every screen, the widget and the
 * watch show — true to how it feels. A stored pose was chosen for a feeling (`statusJson.feels`);
 * when the pet has come to feel otherwise since (tired, ill, gloomy, cheered up), its decision model
 * picks the pose for the new feeling and it is stored. Returns the row as it is afterwards.
 *
 * The widget and the watch find the new pose by its values (their pose key names them), and the
 * phone is woken with the usual status push to redraw them.
 *
 * A pet never posed yet keeps its sticker's defaults until its first interaction. When the model
 * does not answer, the old pose stays and is tried again the next time the pet is seen.
 */
export async function settleRestingPose(
  db: Database,
  row: PetRow,
  petTitle: string,
  configuration: StickerConfiguration | undefined,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetRow> {
  const status = row.statusJson;
  if (!status || !configuration) return row;
  const stats = currentStats(row);
  const feels = describeCondition(stats, row.identityJson?.maxHp ?? 100, row.illnessJson?.name);
  if (status.feels === feels) return row;
  const current = normalizedControlValues(configuration, status.values);
  const decided = await decidePetPose(configuration, current, {
    petTitle, identity: row.identityJson, stats, illness: row.illnessJson?.name,
    moment: "Nothing in particular is happening: this is how it rests, showing how it feels.",
  }, RESTING_DECISION_TIMEOUT_MS);
  if (!decided) return row;
  const next = { ...status, values: normalizedControlValues(configuration, { ...current, ...decided }), feels };
  // Only over the status it was chosen against: an interaction landing meanwhile wins.
  const written = await db.update(userPets).set({ statusJson: next })
    .where(and(eq(userPets.userId, row.userId), eq(userPets.stickerId, row.stickerId),
      sql`${userPets.statusJson} = ${JSON.stringify(status)}::jsonb`))
    .returning({ userId: userPets.userId });
  petLog("pose:resting", { userId: row.userId, pet: petTitle, was: status.feels ?? null, feels, from: current, to: next.values,
    stored: written.length > 0 });
  if (!written.length) return row;
  // The phone redraws the widget and feeds the watch the new pose; wake it in case it is not the one looking.
  await notify(db, row.userId).catch((error) => traceEvent("pet.pose:notify:failed", { userId: row.userId, error: describeError(error) }));
  return { ...row, statusJson: next };
}
