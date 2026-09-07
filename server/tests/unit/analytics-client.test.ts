import { afterEach, beforeEach, expect, it, vi } from "vitest";
const sdk = vi.hoisted(() => ({ logEvent: vi.fn(), initializeAnalytics: vi.fn(() => ({})), isSupported: vi.fn(async () => true) }));
vi.mock("firebase/app", () => ({ getApps: () => [], initializeApp: vi.fn(() => ({})) }));
vi.mock("firebase/analytics", () => sdk);
beforeEach(() => {
  vi.resetModules(); vi.clearAllMocks(); sdk.isSupported.mockResolvedValue(true);
  vi.stubEnv("NEXT_PUBLIC_ANALYTICS_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_API_KEY", "public-config");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_PROJECT_ID", "test");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_APP_ID", "test-app");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_MEASUREMENT_ID", "G-TEST123");
  vi.stubGlobal("window", { location: { origin: "https://example.com", pathname: "/library/private-id" }, addEventListener: vi.fn() });
});
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it("records initial navigation, deduplicates repeated effects, and counts a revisit", async () => {
  const { recordPageView } = await import("@/lib/analytics/client");
  recordPageView("/library/private-id?token=secret");
  recordPageView("/library/private-id?token=secret");
  recordPageView("/marketplace");
  recordPageView("/library/private-id?token=secret");
  await vi.waitFor(() => expect(sdk.logEvent).toHaveBeenCalledTimes(3));
  expect(sdk.initializeAnalytics).toHaveBeenCalledTimes(1);
  expect(sdk.initializeAnalytics.mock.calls[0]).toEqual([{}, { config: expect.objectContaining({ send_page_view: false, page_location: "https://example.com/library/:id", page_referrer: "" }) }]);
  expect(sdk.logEvent.mock.calls.map((call) => call[2].page_location)).toEqual(["https://example.com/library/:id", "https://example.com/marketplace", "https://example.com/library/:id"]);
  expect(JSON.stringify(sdk.logEvent.mock.calls)).not.toMatch(/secret|private-id/);
});
it("skips unsupported browsers", async () => {
  sdk.isSupported.mockResolvedValue(false);
  const { recordPageView } = await import("@/lib/analytics/client");
  recordPageView("/");
  await vi.waitFor(() => expect(sdk.isSupported).toHaveBeenCalled());
  expect(sdk.initializeAnalytics).not.toHaveBeenCalled();
  expect(sdk.logEvent).not.toHaveBeenCalled();
});
it("skips disabled collection", async () => {
  vi.stubEnv("NEXT_PUBLIC_ANALYTICS_ENABLED", "false");
  const { recordPageView } = await import("@/lib/analytics/client");
  recordPageView("/");
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(sdk.initializeAnalytics).not.toHaveBeenCalled();
});
it("bounds error volume and excludes error messages and stacks", async () => {
  const { recordBrowserError } = await import("@/lib/analytics/client");
  for (let i = 0; i < 40; i++) recordBrowserError(new TypeError("password=secret"), "runtime");
  await vi.waitFor(() => expect(sdk.logEvent).toHaveBeenCalledTimes(30));
  expect(sdk.logEvent.mock.calls[0][2]).toMatchObject({ error_type: "TypeError", error_kind: "runtime" });
  expect(JSON.stringify(sdk.logEvent.mock.calls)).not.toContain("secret");
});
it("captures runtime/rejection events and console severity without forwarding arguments", async () => {
  const originals = { log: console.log, info: console.info, warn: console.warn, error: console.error };
  const output = vi.fn();
  console.warn = output;
  try {
    const { installBrowserReporting } = await import("@/lib/analytics/client");
    installBrowserReporting(); installBrowserReporting();
    const listeners = vi.mocked(window.addEventListener).mock.calls;
    expect(listeners).toHaveLength(2);
    const runtime = listeners.find(([name]) => name === "error")![1] as (event: unknown) => void;
    const rejection = listeners.find(([name]) => name === "unhandledrejection")![1] as (event: unknown) => void;
    runtime({ error: new TypeError("secret runtime text") });
    rejection({ reason: "secret rejection" });
    console.warn("secret log", { token: "secret token" });
    await vi.waitFor(() => expect(sdk.logEvent).toHaveBeenCalledTimes(3));
    expect(output).toHaveBeenCalledWith("secret log", { token: "secret token" });
    expect(sdk.logEvent.mock.calls.map((call) => call[1])).toEqual(["web_error", "web_error", "web_log"]);
    expect(JSON.stringify(sdk.logEvent.mock.calls)).not.toContain("secret");
  } finally {
    Object.assign(console, originals);
  }
});
