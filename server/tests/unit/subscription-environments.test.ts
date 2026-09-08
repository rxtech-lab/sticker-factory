import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { eq } from "drizzle-orm";
import { APP_TRANSACTION_HEADER, withBillingRequest } from "@/lib/subscription/environment";
import { verifyAppBillingEnvironment } from "@/lib/subscription/verify-app-transaction";
import { currentBillingEnvironment, fetchEntitlements, recordGenerationUsage } from "@/lib/subscription/client";
import { chargeJobCredits, refundJobCredits, holdCreditsForJob, requirePublishEntitlement } from "@/lib/subscription/credits";
import { subscriptionConfig } from "@/lib/subscription/config";
import { generationJobs, type GenerationJobRow } from "@/lib/db/schema";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedUser } from "@/tests/helpers/packs";
import { createChatTurn, createSticker } from "@/lib/services/stickers";

const principal = { sub: "user-1", clientId: "ios", scopes: [] };
let calls: { path: string; key: string; body: Record<string, unknown> }[];

beforeEach(() => {
  calls = [];
  vi.stubEnv("VERCEL_ENV", "production");
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://billing.example.test");
  vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "");
  vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "");
  vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "rxs_sandbox_test");
  vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_test");
  vi.stubEnv("IOS_OAUTH_CLIENT_ID", "ios");
  vi.stubEnv("AUTH_CLIENT_ID", "web");
  vi.stubEnv("APP_CLIP_OAUTH_CLIENT_ID", "clip");
  vi.stubGlobal("fetch", vi.fn(async (url: URL, init: RequestInit) => {
    const key = new Headers(init.headers).get("x-api-key")!;
    const path = url.pathname;
    calls.push({ path, key, body: init.body ? JSON.parse(String(init.body)) : {} });
    await Promise.resolve();
    return Response.json(path.endsWith("/reserve") ? { reservationId: `hold-${key}` }
      : path.endsWith("/entitlements") ? { permissions: ["marketplace.publish:all"] }
      : { operationShortfallAmount: 0, allowed: true });
  }));
  // Keep the real verifier construction/trust configuration. Replace only its
  // Apple cryptographic boundary for successful fixtures; rejection tests below
  // exercise the real library with fabricated JWS values.
  vi.spyOn(SignedDataVerifier.prototype, "verifyAndDecodeAppTransaction").mockImplementation(async function(this: SignedDataVerifier, proof) {
    const config = this as unknown as { environment: Environment; bundleId: string; appAppleId: number; enableOnlineChecks: boolean };
    expect(config.bundleId).toBe("app.rxlab.stickerfactory");
    expect(config.appAppleId).toBe(6805825708);
    expect(config.enableOnlineChecks).toBe(true);
    const expected = proof === "signed.sandbox.proof" ? Environment.SANDBOX : Environment.PRODUCTION;
    if (config.environment !== expected) throw new VerificationException(VerificationStatus.INVALID_ENVIRONMENT);
    await Promise.resolve();
    return { receiptType: expected };
  });
});

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

function request(environment?: string) {
  return new Request("https://sticker.example.test/api/v1/stickers", {
    headers: environment ? { [APP_TRANSACTION_HEADER]: `signed.${environment}.proof` } : {},
  });
}
function hold() {
  return holdCreditsForJob({ ownerId: principal.sub, amount: 10, idempotencyKey: "reserve:job", description: "Generate" });
}
function job(environment: "sandbox" | "production" | null): GenerationJobRow {
  return { id: "job", kind: "export", reservationId: "hold", reservationAmount: 10, billingEnvironment: environment } as GenerationJobRow;
}
function fakeDb() { return { update: () => ({ set: () => ({ where: async () => {} }) }) } as never; }

it("isolates simultaneous sandbox and production reservations, permissions and usage", async () => {
  await Promise.all((["sandbox", "production"] as const).map(environment =>
    withBillingRequest(request(environment), principal, async () => {
      expect(await hold()).toBe(`hold-rxs_${environment}_test`);
      expect(await currentBillingEnvironment()).toBe(environment);
      await requirePublishEntitlement(principal.sub);
      await recordGenerationUsage(principal.sub, `job-${environment}`);
    })));
  expect(calls.filter(call => call.key === "rxs_sandbox_test")).toHaveLength(3);
  expect(calls.filter(call => call.key === "rxs_production_test")).toHaveLength(3);
  expect(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).toHaveBeenCalledTimes(3);
});

it("uses persisted job environments outside a request and during an opposite-environment request", async () => {
  await chargeJobCredits(fakeDb(), job("sandbox"));
  await withBillingRequest(request("sandbox"), principal, () => refundJobCredits(fakeDb(), job("production"), "cancelled"));
  expect(calls.map(call => call.key)).toEqual(["rxs_sandbox_test", "rxs_production_test"]);
  expect(calls[0].body).toMatchObject({ amount: 10, final: true });
});

it("never assigns a legacy hold to the environment of a later request", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  await withBillingRequest(request("sandbox"), principal, () => chargeJobCredits(fakeDb(), job(null)));
  expect(calls).toHaveLength(0);
});

it("requires proof for mobile billing but keeps reads usable", async () => {
  expect(await withBillingRequest(request(), principal, async () => "read succeeded")).toBe("read succeeded");
  await expect(withBillingRequest(request(), principal, hold)).rejects.toMatchObject({ code: "BILLING_ENVIRONMENT_REQUIRED" });
  expect(calls).toHaveLength(0);
});

it("does not trust a plain environment header or a platform claim", async () => {
  const req = request();
  req.headers.set("x-subscription-environment", "sandbox");
  req.headers.set("x-client-platform", "web");
  await expect(withBillingRequest(req, principal, hold)).rejects.toMatchObject({ status: 403 });
});

it("routes the authenticated web client to production without Apple proof", async () => {
  await withBillingRequest(request(), { ...principal, clientId: "web" }, () => fetchEntitlements(principal.sub));
  expect(calls[0].key).toBe("rxs_production_test");
});

it("does not fall back to production when the verified sandbox key is missing", async () => {
  vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "");
  await expect(withBillingRequest(request("sandbox"), principal, hold)).rejects.toMatchObject({ status: 503 });
  expect(calls).toHaveLength(0);
});

it("verified routing overrides a deployment default", async () => {
  vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "production");
  await withBillingRequest(request("sandbox"), principal, hold);
  expect(calls[0].key).toBe("rxs_sandbox_test");
  expect(subscriptionConfig("production")?.environment).toBe("production");
});

it("persists the reservation environment through the real job creation and migration path", async () => {
  const handle = await createTestDatabase();
  try {
    await seedUser(handle.db, principal.sub, "Tester");
    const turn = await withBillingRequest(request("sandbox"), principal, async () => {
      const sticker = await createSticker(handle.db, principal.sub, { title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [] });
      return createChatTurn(handle.db, principal.sub, sticker.stickerId, {
        text: "Cat", intent: "generate", attachments: [], imagePlacement: "replace",
      });
    });
    const [saved] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
    expect(saved).toMatchObject({ billingEnvironment: "sandbox", reservationId: "hold-rxs_sandbox_test" });
    await chargeJobCredits(handle.db, { ...saved, apiImagePoints: 3 });
    expect(calls.at(-1)?.body.amount).toBe(3);
    expect(calls.at(-1)?.key).toBe("rxs_sandbox_test");
  } finally { await handle.close(); }
});

it.each(["Sandbox", "Production", "Xcode"])("rejects fabricated %s app transactions with the real Apple verifier", async receiptType => {
  vi.restoreAllMocks();
  const header = Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({ receiptType, bundleId: "app.rxlab.stickerfactory", appAppleId: 6805825708 })).toString("base64url");
  await expect(verifyAppBillingEnvironment(`${header}.${payload}.fake`, "ios"))
    .rejects.toMatchObject({ code: "INVALID_BILLING_ENVIRONMENT" });
  expect(calls).toHaveLength(0);
});

it("reports transient Apple verification failures without trying another balance", async () => {
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).mockRejectedValue(new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE));
  await expect(withBillingRequest(request("sandbox"), principal, hold)).rejects.toMatchObject({ status: 503 });
  expect(calls).toHaveLength(0);
});
