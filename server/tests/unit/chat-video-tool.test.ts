import { afterEach, describe, expect, it, vi } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import fixture from "@/fixtures/sticker-document-v4.json";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { getAiProvider, setAiProviderForTests, type AiChatContext } from "@/lib/ai/gateway";

let model: MockLanguageModelV3;
vi.mock("@/e2e/support/chat-model", () => ({ chatModel: () => model }));

function context(): AiChatContext {
  const document = StickerDocumentSchema.parse(fixture);
  const hero = document.layers[0];
  document.layers = StickerDocumentSchema.parse({ ...document, layers: [{
    id: hero.id, name: hero.name, type: "image", hidden: false,
    anchor: hero.anchor, animations: [], assetId: "00000000-0000-4000-8000-000000000001",
  }] }).layers;
  return {
    instruction: "Generate a video of the bird flapping its wings",
    history: "", stickerKind: "animated", document,
    attachmentCount: 0, references: [], priorArt: [], hasPlan: true,
  };
}

function respond(toolName: string, input: unknown) {
  vi.stubEnv("STICKER_FACTORY_E2E", "true");
  model = new MockLanguageModelV3({ doGenerate: {
    content: [{ type: "tool-call", toolCallId: "video-call", toolName, input: JSON.stringify(input) }],
    finishReason: { unified: "tool-calls", raw: "tool_calls" },
    usage: {
      inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: 10, text: 10, reasoning: 0 },
    },
    warnings: [],
  } });
}

function toolNames() {
  return model.doGenerateCalls[0].tools?.map((tool) => tool.name);
}

afterEach(() => {
  vi.unstubAllEnvs();
  setAiProviderForTests();
});

describe("chat video generation tool", () => {
  it("exposes a callable tool and returns a direct video action with a default duration", async () => {
    const input = context();
    const layerId = input.document!.layers[0].id;
    respond("generate-video", { layerId, motion: "flap its wings" });
    expect(await getAiProvider().routeChatTurn(input)).toEqual({
      type: "generate_video", instruction: "flap its wings", layerId, durationSeconds: 3,
    });
    expect(toolNames()).toContain("generate-video");
  });

  it.each(["static", "empty", "existing-video"])("omits video generation for %s stickers", async (kind) => {
    const input = context();
    if (kind === "static") {
      input.stickerKind = "static";
      input.document!.kind = "static";
    } else if (kind === "empty") {
      input.document = undefined;
    } else {
      input.document = StickerDocumentSchema.parse(fixture);
    }
    respond("reply", { message: "Video is unavailable for this sticker." });
    await getAiProvider().routeChatTurn(input);
    expect(toolNames()).not.toContain("generate-video");
  });

  it.each([
    { layerId: "unknown", durationSeconds: 3 },
    { durationSeconds: 10 },
  ])("rejects invalid video targets and duration: %j", async (overrides) => {
    const input = context();
    respond("generate-video", { layerId: input.document!.layers[0].id, motion: "flap wings", ...overrides });
    await expect(getAiProvider().routeChatTurn(input)).rejects.toThrow();
  });
});
