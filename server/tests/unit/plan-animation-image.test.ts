import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { generateConceptImage } from "@/lib/ai/gateway-images";

const { generateImage } = vi.hoisted(() => ({ generateImage: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateImage }));
vi.mock("@/lib/ai/cost", () => ({ recordImageApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { generateImage.mockReset(); });

it("renders the storyboard with the approved pixels and without single-pose or transparency restrictions", async () => {
  const bytes = new Uint8Array(await sharp({ create: {
    width: 1024, height: 1024, channels: 4, background: "white",
  } }).png().toBuffer());
  generateImage.mockResolvedValueOnce({ image: { uint8Array: bytes } });
  const prompt = "Show a labelled wave storyboard, then happy and sad expressions.";
  const output = await generateConceptImage({
    purpose: "animation-summary", prompt, references: [{ bytes, mimeType: "image/png" }],
  });
  expect(generateImage).toHaveBeenCalledTimes(1);
  expect(generateImage.mock.calls[0][0].prompt).toEqual({ text: prompt, images: [bytes] });
  expect(generateImage.mock.calls[0][0].providerOptions?.openai?.background).not.toBe("transparent");
  expect(await sharp(output.bytes).metadata()).toMatchObject({ width: 1024, height: 1024, format: "png" });
});
