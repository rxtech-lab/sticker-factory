import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { downscaleForModelInput } from "@/lib/storage/r2";
import { routeChatTurn } from "@/lib/ai/gateway-chat";

const { generateText } = vi.hoisted(() => ({ generateText: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateText }));
vi.mock("@/lib/ai/cost", () => ({ recordTextApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { generateText.mockReset(); });

it("sends the fourth project image to chat with the animation-summary label", async () => {
  const labels = ["original photo", "current sticker", "resting reference", "illustrated animation summary"];
  const priorArt = await Promise.all(labels.map(async (label, index) => ({
    label,
    image: { bytes: new Uint8Array(await sharp({ create: {
      width: 128, height: 128, channels: 4, background: ["red", "green", "blue", "orange"][index],
    } }).png().toBuffer()), mimeType: "image/png" },
  })));
  generateText.mockResolvedValueOnce({ toolCalls: [{ toolName: "reply", input: { message: "The second pose waves." } }] });
  await expect(routeChatTurn({ instruction: "What is the second pose?", history: "",
    stickerKind: "animated", hasPlan: true, attachmentCount: 0, references: [], priorArt,
  })).resolves.toEqual({ type: "reply", message: "The second pose waves." });
  const request = generateText.mock.calls[0][0];
  const parts = request.messages[0].content;
  expect(parts.find((part: { type: string }) => part.type === "text").text)
    .toContain("(4) illustrated animation summary");
  const images = parts.filter((part: { type: string }) => part.type === "image");
  expect(images).toHaveLength(4);
  expect(images[3].image).toEqual((await downscaleForModelInput(priorArt[3].image.bytes)).bytes);
  expect(request.system).toContain("include that concrete visual description in any delegated action instruction");
});
