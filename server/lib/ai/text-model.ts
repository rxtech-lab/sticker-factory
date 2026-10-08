import { gateway, type GatewayProviderOptions } from "@ai-sdk/gateway";
import { defaultSettingsMiddleware, wrapLanguageModel } from "ai";

/**
 * A gateway text model with prompt caching on. OpenAI caches long prefixes by itself, but Anthropic
 * only caches behind explicit breakpoints, so without this every agent step re-bills the whole
 * system prompt, tools and reference images. `caching: "auto"` lets the gateway place them.
 */
export function textModel(id: string) {
  return wrapLanguageModel({
    model: gateway(id),
    middleware: defaultSettingsMiddleware({
      settings: { providerOptions: { gateway: { caching: "auto" } satisfies GatewayProviderOptions } },
    }),
  });
}

/** The orchestrator that plans, animates, edits and reviews stickers. */
export function orchestratorModel() {
  return textModel(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6");
}

/**
 * The model that draws SVG rigs and scenes. One response carries every group's markup, condition and
 * keyframes, which smaller models cannot hold together, so it is set apart from the orchestrator.
 */
export function svgAuthoringModel() {
  return textModel(process.env.AI_SVG_MODEL ?? process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6");
}
