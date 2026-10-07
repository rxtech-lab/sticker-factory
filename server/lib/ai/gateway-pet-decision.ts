// The pet's decision model: snap judgments about the pet — which pose it strikes — answered as
// typed choices with probabilities in well under a second, rather than written out by an LLM.
// TypeSafe's Jev by default; `AI_PET_DECISION_MODEL` swaps in any decision model on AI Gateway.

import { gateway } from "@ai-sdk/gateway";
import { experimental_decide as decide, type Experimental_DecisionModel, type Experimental_DecisionQuestion } from "ai";

export type PetDecisionQuestion = Experimental_DecisionQuestion;

/** The decision model every pet judgment goes to. */
export function petDecisionModel(): Experimental_DecisionModel {
  return gateway.decisionModel(process.env.AI_PET_DECISION_MODEL ?? "typesafe-ai/jev");
}

/** Asks the decision model `questions` about `state`, and returns its answers keyed like the questions. */
export async function decideForPet<const QUESTIONS extends Record<string, PetDecisionQuestion>>(
  state: Parameters<typeof decide>[0]["state"],
  questions: QUESTIONS,
  options: { timeoutMs?: number; model?: Experimental_DecisionModel } = {},
) {
  const result = await decide({
    model: options.model ?? petDecisionModel(),
    state,
    questions,
    // A judgment that has to be retried is already too late for what it decides.
    maxRetries: 0,
    abortSignal: AbortSignal.timeout(options.timeoutMs ?? 5_000),
  });
  return result.answers;
}
