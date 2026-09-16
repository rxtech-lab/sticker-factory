import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { refineStickerLayout } from "@/lib/ai/gateway-plan";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

const { generateText } = vi.hoisted(() => ({ generateText: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateText }));
vi.mock("@/lib/ai/cost", () => ({ recordTextApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { generateText.mockReset(); });

it("attaches the summary pixels to the build review model with their separate reference role", async () => {
  const bytes = new Uint8Array(await sharp({ create: {
    width: 128, height: 128, channels: 4, background: "white",
  } }).png().toBuffer());
  const document = StickerDocumentSchema.parse({
    version: 5, kind: "static", canvas: { width: 1024, height: 1024, coordinateSpace: "normalized" },
    durationSeconds: 0, fps: 0, loop: "once", layers: [],
  });
  generateText.mockResolvedValueOnce({});
  await refineStickerLayout({ document, instruction: "Review the wave and smile", history: "",
    animationSummary: { bytes, mimeType: "image/png" },
  }, {
    viewPlanImage: vi.fn(), renderSticker: vi.fn(), applyLayout: vi.fn(), finalizeLayout: vi.fn(),
  });
  const messages = generateText.mock.calls[0][0].messages;
  const parts = messages[0].content;
  expect(parts.find((part: { type: string }) => part.type === "text").text)
    .toContain("approved illustrated animation summary");
  expect(parts.find((part: { type: string }) => part.type === "text").text)
    .toContain("Do not reproduce the storyboard panels");
  const pictures = parts.filter((part: { type: string }) => part.type === "image");
  expect(pictures).toHaveLength(1);
  expect(pictures[0].image.byteLength).toBeGreaterThan(0);
});
