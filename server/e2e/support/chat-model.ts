import { MockLanguageModelV3 } from "ai/test";

// Only loaded by the development mock provider. The real router still builds its prompt,
// declares tools, and validates the provider's tool call through generateText.
export function chatModel() {
  return new MockLanguageModelV3({
    doGenerate: {
      content: [{
        type: "tool-call",
        toolCallId: "e2e-reply",
        toolName: "reply",
        input: JSON.stringify({ message: "AI SDK mock reply: your sticker is ready to discuss." }),
      }],
      finishReason: { unified: "tool-calls", raw: "tool_calls" },
      usage: {
        inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
        outputTokens: { total: 10, text: 10, reasoning: 0 },
      },
      providerMetadata: { gateway: { cost: "0.0001" } },
      warnings: [],
    },
  });
}
