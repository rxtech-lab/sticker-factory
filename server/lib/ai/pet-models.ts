// Which models the pet thinks with. Two roles, each set on its own:
//
// - `AI_PET_AGENT_MODEL`: the pet's agent — its lines, actions, places, encounters, memory and shop.
// - `AI_PET_DECISION_MODEL`: the quick call that picks the pose and expression the pet answers its
//   owner with. It runs while the owner is watching, so it wants a fast model.
//
// Each falls back to the models the pet used before these existed, so leaving them unset changes nothing.

import { textModel } from "./text-model";

export function petAgentModelId(): string {
  return process.env.AI_PET_AGENT_MODEL ?? process.env.AI_SUMMARY_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6";
}

export function petDecisionModelId(): string {
  return process.env.AI_PET_DECISION_MODEL ?? petAgentModelId();
}

export function petAgentModel() {
  return textModel(petAgentModelId());
}

export function petDecisionModel() {
  return textModel(petDecisionModelId());
}
