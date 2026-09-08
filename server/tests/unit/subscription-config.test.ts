import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { subscriptionConfig, subscriptionEnabled } from "@/lib/subscription/config";
import { holdCreditsForJob } from "@/lib/subscription/credits";

beforeEach(() => {
  for (const name of ["RX_SUBSCRIPTION_URL", "RX_SUBSCRIPTION_API_KEY",
    "RX_SUBSCRIPTION_ENVIRONMENT", "RX_SUBSCRIPTION_SANDBOX_API_KEY",
    "RX_SUBSCRIPTION_PRODUCTION_API_KEY", "VERCEL_ENV"]) vi.stubEnv(name, "");
  vi.stubEnv("NODE_ENV", "test");
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

function deployedKeys() {
  vi.stubEnv("VERCEL_ENV", "production");
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://billing.example.test/");
  vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "rxs_sandbox_test");
  vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_test");
}

describe("subscription deployment configuration", () => {
  it("rejects the deployed split-key configuration without an environment instead of disabling billing", async () => {
    deployedKeys();
    await expect(holdCreditsForJob({ ownerId: "u", amount: 10,
      idempotencyKey: "reserve:j", description: "Sticker generate" }))
      .rejects.toMatchObject({ status: 503, code: "SUBSCRIPTION_NOT_CONFIGURED" });
  });

  it.each(["sandbox", "production"])("uses the selected %s key for the actual reservation", async environment => {
    deployedKeys();
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", environment);
    // Explicit selection must also override an old deployment-wide key.
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_xcode_legacy");
    const fetch = vi.fn(async () => Response.json({ reservationId: "res-1" }));
    vi.stubGlobal("fetch", fetch);
    await expect(holdCreditsForJob({ ownerId: "u", amount: 10,
      idempotencyKey: "reserve:j", description: "Sticker generate" })).resolves.toBe("res-1");
    expect(fetch).toHaveBeenCalledWith(new URL("https://billing.example.test/api/v1/balances/reserve"),
      expect.objectContaining({ headers: expect.objectContaining({ "x-api-key": `rxs_${environment}_test` }) }));
  });

  it("never falls back to another environment when the selected key is missing", () => {
    deployedKeys();
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_production_legacy");
    expect(subscriptionConfig).toThrow();
  });

  it("rejects a key from the wrong environment", () => {
    deployedKeys();
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "rxs_production_wrong");
    expect(subscriptionConfig).toThrow();
  });

  it("rejects unknown environment names", () => {
    deployedKeys();
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "testflight");
    expect(subscriptionConfig).toThrow();
  });

  it.each(["production", "preview"])("fails closed on an unconfigured Vercel %s deployment", environment => {
    vi.stubEnv("VERCEL_ENV", environment);
    expect(subscriptionEnabled).toThrow();
  });

  it("fails closed on an unconfigured standalone production server", () => {
    vi.stubEnv("NODE_ENV", "production");
    expect(subscriptionEnabled).toThrow();
  });

  it("preserves unconfigured local tests", () => {
    expect(subscriptionEnabled()).toBe(false);
  });

  it("preserves the legacy single-key configuration", () => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", "https://billing.example.test/");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_xcode_legacy");
    expect(subscriptionConfig()).toEqual({ baseURL: "https://billing.example.test", apiKey: "rxs_xcode_legacy", environment: "xcode" });
  });
});
