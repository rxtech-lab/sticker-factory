import { afterEach, expect, it, vi } from "vitest";
import { CHROMA_GREEN } from "@/lib/ai/chroma-key";

const { requests, recordVideoApiCost } = vi.hoisted(() => ({
  requests: [] as Array<{ url: string; model: string | null; body: Record<string, unknown> }>,
  recordVideoApiCost: vi.fn().mockResolvedValue("reported"),
}));

vi.mock("@/lib/ai/cost", () => ({ recordVideoApiCost }));
vi.mock("@ai-sdk/gateway", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ai-sdk/gateway")>();
  return {
    ...actual,
    gateway: actual.createGateway({
      apiKey: "test-key",
      baseURL: "https://gateway.test",
      fetch: async (url, init) => {
        requests.push({
          url: String(url),
          model: new Headers(init?.headers).get("ai-model-id"),
          body: JSON.parse(String(init?.body)),
        });
        if (String(url).endsWith("/start")) {
          return Response.json({ error: {
            message: "Model 'minimax/minimax-h3-max' is not supported for async video generation yet.",
          } }, { status: 400 });
        }
        return new Response(`data: ${JSON.stringify({
          type: "result",
          videos: [{ type: "base64", data: "AQID", mediaType: "video/mp4" }],
          warnings: [],
        })}\n\n`, { headers: { "content-type": "text/event-stream" } });
      },
    }),
  };
});

afterEach(() => vi.unstubAllEnvs());

it("generates MiniMax video through the synchronous Gateway endpoint using the real SDK", async () => {
  vi.stubEnv("AI_VIDEO_MODEL", "minimax/minimax-h3-max");
  vi.stubEnv("NODE_ENV", "production");
  const { getAiProvider } = await import("@/lib/ai/gateway");
  const result = await getAiProvider().generateStickerVideo({
    imageUrl: "https://assets.test/approved-still.png",
    motion: "rotate while eating",
    durationSeconds: 3,
    keyColor: CHROMA_GREEN,
  });

  expect(requests).toHaveLength(1);
  expect(requests[0]).toMatchObject({
    url: "https://gateway.test/video-model",
    model: "minimax/minimax-h3-max",
    body: { duration: 3, aspectRatio: "1:1", fps: 24 },
  });
  expect(JSON.stringify(requests[0].body)).toContain("https://assets.test/approved-still.png");
  expect(result).toEqual({
    bytes: new Uint8Array([1, 2, 3]),
    mimeType: "video/mp4",
    modelId: "minimax/minimax-h3-max",
  });
  expect(recordVideoApiCost).toHaveBeenCalledOnce();
});
