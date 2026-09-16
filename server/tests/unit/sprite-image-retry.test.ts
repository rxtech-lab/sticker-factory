import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { generateStickerImage } from "@/lib/ai/gateway-images";

const { generateImage } = vi.hoisted(() => ({ generateImage: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateImage }));
vi.mock("@/lib/ai/cost", () => ({ recordImageApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { vi.unstubAllEnvs(); generateImage.mockReset(); });

it.each([
  { columns: 3, rows: 2, count: 4, facePlaceholder: true },
  { columns: 3, rows: 2, count: 4, facePlaceholder: true, faceRegion: "the windshield" },
  { columns: 2, rows: 2, count: 3, tiles: true },
  { columns: 2, rows: 2, count: 3, tiles: true, faceRegion: "the windshield" },
])("preserves sheet layout during background removal: %j", async (sheet) => {
  vi.stubEnv("FIRECRAWL_API_KEY", "");
  const opaque = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "white" } }).png().toBuffer();
  const transparent = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer();
  generateImage.mockResolvedValueOnce({ image: { uint8Array: opaque } })
    .mockResolvedValueOnce({ image: { uint8Array: transparent } });

  await generateStickerImage({ prompt: "Controllable cartoon car braking", references: [], mode: "generate", keepFrame: true, quality: "medium", sheet });

  expect(generateImage).toHaveBeenCalledTimes(2);
  const retry = generateImage.mock.calls[1][0];
  expect(retry.prompt.text).toContain(`grid of ${sheet.columns} columns by ${sheet.rows} rows`);
  expect(retry.prompt.text).toContain(`exactly ${sheet.count} drawings`);
  expect(retry.prompt.text).not.toContain("Never draw a grid");
  expect(retry.providerOptions.openai.quality).toBe("medium");
  if (sheet.facePlaceholder) expect(retry.prompt.text).toContain("#FF00FF");
  if (sheet.tiles) expect(retry.prompt.text).toContain("inner facial patch");
  if (sheet.faceRegion) expect(retry.prompt.text).toContain("the windshield");
  else expect(retry.prompt.text).not.toContain("face region is");
  expect(retry.prompt.images).toHaveLength(1);
});
