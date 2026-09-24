import { readFileSync } from "node:fs";
import { expect, it, vi } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { refineStickerLayout } from "@/lib/ai/gateway-plan";
import type { LayoutDraftingSession } from "@/lib/ai/gateway-contracts";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

let model: MockLanguageModelV3;
vi.mock("@ai-sdk/gateway", () => ({ gateway: () => model }));

const call = (toolName: string) => ({
  content: [{ type: "tool-call" as const, toolCallId: `${toolName}-${Math.random()}`, toolName, input: "{}" }],
  finishReason: { unified: "tool-calls" as const, raw: "tool_calls" },
  usage: {
    inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
    outputTokens: { total: 10, text: 10, reasoning: 0 },
  },
  warnings: [],
});

// Production: the reviewer called finalize_layout after one configuration, `finalizeLayout`
// rejected it, and the loop stopped on the call anyway — so the job failed with
// "Expression review did not finish" on every retry.
it("keeps the review loop running after a rejected finalize_layout", async () => {
  const document = StickerDocumentSchema.parse(JSON.parse(readFileSync("fixtures/sticker-document-v5-cast.json", "utf8")));
  const steps = ["finalize_layout", "finalize_layout"];
  model = new MockLanguageModelV3({ doGenerate: async () => call(steps.shift() ?? "finalize_layout") });
  let attempts = 0;
  const session = {
    renderSticker: vi.fn(),
    applyLayout: vi.fn(),
    finalizeLayout: vi.fn(async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("Review all 4 configurations with view_sticker before finalizing; 1 viewed");
      return { revision: 0, document };
    }),
  } as unknown as LayoutDraftingSession;

  const result = await refineStickerLayout({ document, instruction: "Review", history: "" }, session);

  expect(attempts).toBe(2);
  expect(model.doGenerateCalls).toHaveLength(2);
  expect(result).toEqual({ revision: 0, finalized: true });
});
