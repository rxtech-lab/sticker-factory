import { readFileSync } from "node:fs";
import { expect, it, vi } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { animateSticker } from "@/lib/ai/gateway-animate";
import type { AnimationDraftingSession } from "@/lib/ai/gateway-contracts";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

let model: MockLanguageModelV3;
vi.mock("@ai-sdk/gateway", () => ({ gateway: () => model }));

const operations = [{ op: "setLayerAnimations", layerId: "hero", animations: [] }];
const step = (...calls: Array<[string, unknown]>) => ({
  content: calls.map(([toolName, input], index) => ({ type: "tool-call" as const, toolCallId: `${toolName}-${index}-${Math.random()}`, toolName, input: JSON.stringify(input) })),
  finishReason: { unified: "tool-calls" as const, raw: "tool_calls" },
  usage: {
    inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
    outputTokens: { total: 10, text: 10, reasoning: 0 },
  },
  warnings: [],
});

// Production: the model sent a fix and finalize_animation in one step. The fix was rejected, but
// finalize succeeded on the old revision and ended the loop, so the rejection was never answered.
it("does not finalize over a rejected change sent in the same step", async () => {
  const document = StickerDocumentSchema.parse(JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")));
  const steps = [
    step(["create_animation", { operations }]),
    step(["update_animation", { animationId: "anim", operations }], ["finalize_animation", { animationId: "anim" }]),
    step(["update_animation", { animationId: "anim", operations }]),
    step(["finalize_animation", { animationId: "anim" }]),
  ];
  model = new MockLanguageModelV3({ doGenerate: async () => steps.shift()! });
  let updates = 0, revision = 0;
  const landed = async () => ({ animationId: "anim", revision: ++revision, document });
  const session = {
    renderSticker: vi.fn(),
    createAnimation: vi.fn(landed),
    updateAnimation: vi.fn(async () => {
      updates += 1;
      // Slower than finalize, so finalize would read the pre-fix state without waiting.
      await new Promise((resolve) => setTimeout(resolve, 20));
      if (updates === 1) throw new Error("Timing overlaps the loop point");
      return landed();
    }),
    editLayerAnimation: vi.fn(landed),
    finalizeAnimation: vi.fn(async () => ({ animationId: "anim", revision, document })),
  } as unknown as AnimationDraftingSession;

  const result = await animateSticker({ document, instruction: "Animate", history: "", references: [] }, session);

  expect(model.doGenerateCalls).toHaveLength(4);
  expect(session.finalizeAnimation).toHaveBeenCalledTimes(1);
  expect(result).toEqual({ animationId: "anim", revision: 2, finalized: true });
  expect(JSON.stringify(model.doGenerateCalls[2].prompt)).toContain("your last animation change was rejected");
});
