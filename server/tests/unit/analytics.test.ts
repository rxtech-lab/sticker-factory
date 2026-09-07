import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { analyticsPath, errorCategory } from "@/lib/analytics/shared";
const scheduled = vi.hoisted(() => [] as Array<() => Promise<void>>);
vi.mock("next/server", () => ({ after: (fn: () => Promise<void>) => scheduled.push(fn) }));
import { recordServerEvent, sendServerEvent } from "@/lib/analytics/server";

beforeEach(() => {
  scheduled.length = 0;
  vi.stubEnv("GOOGLE_ANALYTICS_SERVER_ENABLED", "true");
  vi.stubEnv("GOOGLE_ANALYTICS_API_SECRET", "test-secret");
  vi.stubEnv("NEXT_PUBLIC_FIREBASE_MEASUREMENT_ID", "G-TEST123");
});
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe("analytics privacy and delivery", () => {
  it("masks identifiers and strips query/hash values", () => {
    expect(analyticsPath("/api/v1/devices/private-device-token?token=secret#private")).toBe("/api/v1/devices/:id");
    expect(analyticsPath("/marketplace/creators/person@example.com")).toBe("/marketplace/creators/:id");
    expect(errorCategory(new Error("token=secret"))).toBe("Error");
  });
  it("does nothing with missing secret or disabled reporting", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    vi.stubEnv("GOOGLE_ANALYTICS_API_SECRET", "");
    await sendServerEvent("api_request", { path: "/", method: "GET" });
    vi.stubEnv("GOOGLE_ANALYTICS_API_SECRET", "test-secret");
    vi.stubEnv("GOOGLE_ANALYTICS_SERVER_ENABLED", "false");
    recordServerEvent("api_request", { path: "/", method: "GET" });
    expect(fetch).not.toHaveBeenCalled(); expect(scheduled).toHaveLength(0);
  });
  it("defers delivery and excludes sensitive and arbitrary fields", async () => {
    const fetch = vi.fn().mockResolvedValue({ ok: true }); vi.stubGlobal("fetch", fetch);
    recordServerEvent("server_log", { path: "/api/v1/stickers/private-id?access_token=secret", method: "POST", logCode: "secret-freeform-message" });
    expect(fetch).not.toHaveBeenCalled();
    await scheduled[0]();
    const [url, request] = fetch.mock.calls[0];
    expect(new URL(url).searchParams.get("api_secret")).toBe("test-secret");
    expect(JSON.parse(request.body)).toEqual({ client_id: "server.operations", non_personalized_ads: true, events: [{ name: "server_log", params: { source: "server", route: "/api/v1/stickers/:id", method: "POST", log_code: "application_event" } }] });
    expect(request.signal).toBeInstanceOf(AbortSignal);
  });
  it("swallows delivery failures without logging secret-bearing errors", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("https://example?api_secret=test-secret")));
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    await expect(sendServerEvent("server_error", { path: "/", method: "GET" })).resolves.toBeUndefined();
    expect(JSON.stringify(warn.mock.calls)).not.toContain("test-secret");
  });
});
