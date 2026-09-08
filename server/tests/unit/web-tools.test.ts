import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MockLanguageModelV3 } from "ai/test";
import { createWebTools } from "@/lib/ai/web-tools";
import { planSticker } from "@/lib/ai/gateway-plan";
import { routeChatTurn } from "@/lib/ai/gateway-chat";
import { researchGenerationPrompt } from "@/lib/ai/generation-research";

let model: MockLanguageModelV3;
vi.mock("@ai-sdk/gateway", () => ({ gateway: () => model }));
const fetchMock = vi.fn();
const options = { toolCallId: "web-call", messages: [], context: {} };
const crawlId = "00000000-0000-4000-8000-000000000001";
const webNames = ["web_search", "web_scrape", "web_crawl", "web_crawl_status"];
const ok = (value: unknown) => new Response(JSON.stringify(value), { status: 200 });
function call(toolName: string, input: unknown) {
  return {
    content: [{ type: "tool-call" as const, toolCallId: toolName, toolName, input: JSON.stringify(input) }],
    finishReason: { unified: "tool-calls" as const, raw: "tool_calls" },
    usage: {
      inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: 10, text: 10, reasoning: 0 },
    },
    warnings: [],
  };
}
beforeEach(() => {
  vi.stubEnv("FIRECRAWL_API_KEY", "test-firecrawl-secret");
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.clearAllMocks(); });

describe("Firecrawl web tools", () => {
  it("authenticates with the server env key and bounds search content", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { web: [{ url: "https://example.com", title: "Birds", markdown: "x".repeat(9_000) }] } }));
    const tools = createWebTools();
    const result = await tools.web_search.execute!({ query: "bird", limit: 3 }, options);
    expect(fetchMock).toHaveBeenCalledWith("https://api.firecrawl.dev/v2/search", expect.objectContaining({
      method: "POST", headers: expect.objectContaining({ Authorization: "Bearer test-firecrawl-secret" }),
      body: JSON.stringify({ query: "bird", limit: 3, sources: ["web"], scrapeOptions: { formats: ["markdown"] } }),
    }));
    expect(result).toEqual({ sources: [{ url: "https://example.com", title: "Birds", description: undefined, markdown: "x".repeat(8_000), truncated: true }] });
  });
  it("reads a page and retains its source URL", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { markdown: "facts", metadata: { sourceURL: "https://example.com", title: "Example" } } }));
    expect(await createWebTools().web_scrape.execute!({ url: "https://example.com" }, options)).toMatchObject({ url: "https://example.com", markdown: "facts" });
  });
  it("starts a bounded crawl and retrieves its pages", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, id: crawlId }))
      .mockResolvedValueOnce(ok({ status: "scraping", total: 2, completed: 0, data: [] }))
      .mockResolvedValueOnce(ok({ status: "completed", total: 2, completed: 2, data: [{ markdown: "one" }, { markdown: "two" }] }));
    const tools = createWebTools();
    await tools.web_crawl.execute!({ url: "https://example.com", limit: 2 }, options);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toMatchObject({ limit: 2, allowExternalLinks: false });
    expect(await tools.web_crawl_status.execute!({ id: crawlId, skip: 0 }, options)).toMatchObject({ status: "scraping", sources: [] });
    expect(await tools.web_crawl_status.execute!({ id: crawlId, skip: 0 }, options)).toMatchObject({ status: "completed", sources: [{ markdown: "one" }, { markdown: "two" }] });
    await expect(createWebTools().web_crawl_status.execute!({ id: crawlId, skip: 0 }, options)).rejects.toThrow("not started by this agent");
  });
  it("fails clearly without the key and makes no request", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "");
    await expect(createWebTools().web_search.execute!({ query: "bird", limit: 1 }, options)).rejects.toThrow("FIRECRAWL_API_KEY is not configured");
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it.each([401, 402, 429, 500])("does not expose provider error bodies for HTTP %i", async (status) => {
    fetchMock.mockResolvedValueOnce(new Response("test-firecrawl-secret", { status }));
    await expect(createWebTools().web_search.execute!({ query: "bird", limit: 1 }, options)).rejects.toThrow(`Firecrawl request failed (HTTP ${status}).`);
  });
  it("reports network timeouts without exposing fetch internals", async () => {
    fetchMock.mockRejectedValueOnce(new Error("test-firecrawl-secret"));
    await expect(createWebTools().web_search.execute!({ query: "bird", limit: 1 }, options)).rejects.toThrow("Firecrawl request failed or timed out.");
  });
  it("passes agent cancellation through to the request", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { web: [] } }));
    const controller = new AbortController();
    await createWebTools().web_search.execute!({ query: "bird", limit: 1 }, { ...options, abortSignal: controller.signal });
    const signal = fetchMock.mock.calls[0][1].signal as AbortSignal;
    controller.abort();
    expect(signal.aborted).toBe(true);
  });
  it.each([{ success: false, error: "secret" }, null])("rejects unsuccessful API envelopes", async (body) => {
    fetchMock.mockResolvedValueOnce(ok(body));
    await expect(createWebTools().web_search.execute!({ query: "bird", limit: 1 }, options)).rejects.toThrow("Firecrawl could not complete");
  });
});

describe("agent web research loops", () => {
  it("lets chat search, consume results, then return exactly one final action", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { web: [{ url: "https://example.com", markdown: "A bird fact" }] } }));
    model = new MockLanguageModelV3({ doGenerate: [call("web_search", { query: "bird", limit: 1 }), call("reply", { message: "A bird fact (https://example.com)." })] });
    expect(await routeChatTurn({ instruction: "Look up a bird fact", history: "", stickerKind: "static", attachmentCount: 0, references: [], priorArt: [], hasPlan: false }, model)).toEqual({ type: "reply", message: "A bird fact (https://example.com)." });
    expect(model.doGenerateCalls).toHaveLength(2);
    expect(model.doGenerateCalls[0].tools?.map((tool) => tool.name)).toEqual(expect.arrayContaining(webNames));
    expect(JSON.stringify(model.doGenerateCalls[1].prompt)).toContain("A bird fact");
  });
  it("lets planning research before creating and finalizing a plan", async () => {
    const plan = {
      version: 1, title: "Bird", summary: "A blue bird", kind: "static",
      layers: [{ layerId: "bird", name: "Bird", source: { kind: "generate", prompt: "Blue bird" }, x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8 }],
    };
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { web: [{ url: "https://example.com", markdown: "Blue wings" }] } }));
    model = new MockLanguageModelV3({ doGenerate: [
      call("web_search", { query: "bird", limit: 1 }),
      call("create_plan", { plan }), call("finalize_plan", { planId: "plan-1" }),
    ] });
    const session = {
      createPlan: vi.fn().mockResolvedValue({ planId: "plan-1", revision: 1 }),
      updatePlan: vi.fn(), showPlan: vi.fn(),
      finalizePlan: vi.fn().mockResolvedValue({ planId: "plan-1", revision: 1 }),
    };
    expect(await planSticker({ instruction: "Research and plan a bird", history: "", stickerKind: "static", rejectedReasons: [], sequenceAssets: [], references: [], priorArt: [] }, session))
      .toEqual({ planId: "plan-1", revision: 1, finalized: true });
    expect(session.createPlan).toHaveBeenCalledOnce();
    expect(model.doGenerateCalls[0].tools?.map((tool) => tool.name)).toEqual(expect.arrayContaining(webNames));
    expect(JSON.stringify(model.doGenerateCalls[1].prompt)).toContain("Blue wings");
  });
  it("passes generation research to media prompts while preserving the original instruction", async () => {
    fetchMock.mockResolvedValueOnce(ok({ success: true, data: { markdown: "Blue wings", metadata: { sourceURL: "https://example.com" } } }));
    model = new MockLanguageModelV3({ doGenerate: [call("web_scrape", { url: "https://example.com" }), call("finish_research", { notes: "Blue wings — https://example.com" })] });
    const result = await researchGenerationPrompt("Draw the bird from https://example.com");
    expect(result).toMatch(/^Draw the bird from https:\/\/example.com/);
    expect(result).toContain("Blue wings — https://example.com");
    expect(model.doGenerateCalls[0].tools?.map((tool) => tool.name)).toEqual(expect.arrayContaining(webNames));
  });
  it("keeps generation unchanged when research is unnecessary", async () => {
    model = new MockLanguageModelV3({ doGenerate: call("finish_research", { notes: "" }) });
    expect(await researchGenerationPrompt("Draw a happy cat")).toBe("Draw a happy cat");
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("keeps generation working without Firecrawl configuration", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "");
    expect(await researchGenerationPrompt("Draw a cat")).toBe("Draw a cat");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
