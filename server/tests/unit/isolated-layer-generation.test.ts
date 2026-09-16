import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { generateStickerImage } from "@/lib/ai/gateway-images";

const { generateImage, generateText } = vi.hoisted(() => ({ generateImage: vi.fn(), generateText: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateImage, generateText }));
vi.mock("@/lib/ai/cost", () => ({ recordImageApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { vi.unstubAllEnvs(); vi.clearAllMocks(); });

// A visible element with padding, so the real normalization/keying path runs as well as the SDK call.
async function artwork(background: string) {
  return sharp(Buffer.from(`<svg width="1024" height="1024"><rect width="1024" height="1024" fill="${background}"/><rect x="256" y="384" width="512" height="256" fill="black"/></svg>`)).png().toBuffer();
}

it.each([false, true])("sends a lettering-only request to the image model (quick=%s)", async (quick) => {
  vi.stubEnv("FIRECRAWL_API_KEY", "");
  const transparent = await artwork("none");
  generateImage.mockResolvedValue({ image: { uint8Array: transparent } });
  generateText.mockResolvedValue({
    files: [{ mediaType: "image/png", uint8Array: await artwork("#00FF00") }], steps: [],
  });
  await generateStickerImage({
    prompt: 'Cartoon lettering "gogogog!"', references: [{ bytes: transparent, mimeType: "image/png" }],
    mode: "generate", isolatedLayer: true, quick,
    conversationContext: "Draw a red car driving along an orange road.",
  });
  const prompt = quick
    ? generateText.mock.calls[0][0].messages[0].content[0].text
    : generateImage.mock.calls[0][0].prompt.text;
  expect(prompt).toContain('Cartoon lettering "gogogog!"');
  expect(prompt).toContain("draw only the exact requested words");
  expect(prompt).toContain("References provide style or likeness only");
  expect(prompt).not.toContain("red car driving");
  expect(prompt).not.toContain("Generate the sticker described");
  expect(quick ? generateText : generateImage).toHaveBeenCalledTimes(1);
});

it("keeps the requested lettering isolated when retrying an opaque output", async () => {
  vi.stubEnv("FIRECRAWL_API_KEY", "");
  generateImage.mockResolvedValueOnce({ image: { uint8Array: await artwork("white") } })
    .mockResolvedValueOnce({ image: { uint8Array: await artwork("none") } });
  await generateStickerImage({
    prompt: 'Cartoon lettering "gogogog!"', references: [], mode: "generate", isolatedLayer: true,
  });
  expect(generateImage).toHaveBeenCalledTimes(2);
  const retry = generateImage.mock.calls[1][0];
  expect(retry.prompt.text).toContain('Cartoon lettering "gogogog!"');
  expect(retry.prompt.text).toContain("Remove the background and any unrelated illustration");
  expect(retry.prompt.text).toContain("draw only the exact requested words");
  expect(retry.prompt.images).toHaveLength(1);
});
