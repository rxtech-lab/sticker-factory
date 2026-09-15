import { expect, it } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { routeChatTurn } from "@/lib/ai/gateway-chat";
import type { AiChatContext } from "@/lib/ai/gateway-contracts";

function context(): AiChatContext {
  return {
    instruction: "Retry the expressions step", history: "", stickerKind: "animated",
    attachmentCount: 0, references: [], priorArt: [], hasPlan: true,
    retryableGeneration: {
      jobId: "failed-job", kind: "compose", instruction: "Build the approved cat plan", state: "cancelled",
      steps: [
        { id: "pose", name: "compose-sprite Cat wave", status: "complete" },
        { id: "expressions", name: "compose-sprite Cat expressions", status: "failed" },
      ],
    },
  };
}

function modelFor(toolName: string, input: unknown) {
  return new MockLanguageModelV3({ doGenerate: {
    content: [{ type: "tool-call", toolCallId: "retry-call", toolName, input: JSON.stringify(input) }],
    finishReason: { unified: "tool-calls", raw: "tool_calls" },
    usage: {
      inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: 10, text: 10, reasoning: 0 },
    },
    warnings: [],
  } });
}

it.each([{}, { stepId: "expressions" }])("offers a callable retry tool for the original generation or a failed step: %j", async (selection) => {
  const model = modelFor("retry-generation", selection);
  expect(await routeChatTurn(context(), model)).toEqual({ type: "retry_generation", ...selection });
  expect(model.doGenerateCalls[0].tools?.map((tool) => tool.name)).toContain("retry-generation");
  expect(JSON.stringify(model.doGenerateCalls[0].prompt)).toContain("compose-sprite Cat wave");
  expect(JSON.stringify(model.doGenerateCalls[0].prompt)).toContain("Build the approved cat plan");
});

it("does not expose retry when there is no interrupted generation", async () => {
  const input = context();
  input.retryableGeneration = undefined;
  const model = modelFor("reply", { message: "There is no interrupted generation." });
  await routeChatTurn(input, model);
  expect(model.doGenerateCalls[0].tools?.map((tool) => tool.name)).not.toContain("retry-generation");
});

it.each(["unknown", "pose"])("rejects retrying an unavailable step: %s", async (stepId) => {
  await expect(routeChatTurn(context(), modelFor("retry-generation", { stepId }))).rejects.toThrow();
});
