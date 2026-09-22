import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { eq } from "drizzle-orm";
import { APP_TRANSACTION_HEADER, TRANSACTION_HEADER, withBillingRequest } from "@/lib/subscription/environment";
import { verifyAppBillingEnvironment } from "@/lib/subscription/verify-app-transaction";
import { currentBillingEnvironment, fetchEntitlements, recordGenerationUsage } from "@/lib/subscription/client";
import { chargeJobCredits, refundJobCredits, holdCreditsForJob, requirePublishEntitlement } from "@/lib/subscription/credits";
import { subscriptionConfig } from "@/lib/subscription/config";
import { generationJobs, users, type GenerationJobRow } from "@/lib/db/schema";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedUser } from "@/tests/helpers/packs";
import { createChatTurn, createExportJob, createSticker } from "@/lib/services/stickers";

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
  vi.spyOn(SignedDataVerifier.prototype, "verifyAndDecodeTransaction").mockImplementation(async function(this: SignedDataVerifier, proof) {
    const config = this as unknown as { environment: Environment };
    const expected = proof === "signed.sandbox.purchase" ? Environment.SANDBOX : Environment.PRODUCTION;
    if (config.environment !== expected) throw new VerificationException(VerificationStatus.INVALID_ENVIRONMENT);
    await Promise.resolve();
    return { environment: expected };
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

it("bills a mobile request without proof against production and keeps reads usable", async () => {
  expect(await withBillingRequest(request(), principal, async () => "read succeeded")).toBe("read succeeded");
  expect(await withBillingRequest(request(), principal, hold)).toBe("hold-rxs_production_test");
  expect(await withBillingRequest(request(), { ...principal, clientId: "clip" }, hold)).toBe("hold-rxs_production_test");
  expect(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).not.toHaveBeenCalled();
});

it("does not trust a plain environment header or a platform claim", async () => {
  const req = request();
  req.headers.set("x-subscription-environment", "sandbox");
  req.headers.set("x-client-platform", "web");
  expect(await withBillingRequest(req, principal, hold)).toBe("hold-rxs_production_test");
});

it("still refuses a client that is neither the web app nor one of the mobile apps", async () => {
  await expect(withBillingRequest(request(), { ...principal, clientId: "partner" }, hold))
    .rejects.toMatchObject({ status: 403, code: "BILLING_ENVIRONMENT_REQUIRED" });
  expect(calls).toHaveLength(0);
});

it("reuses the last Apple-verified environment when StoreKit cannot produce a proof", async () => {
  const handle = await createTestDatabase();
  try {
    await seedUser(handle.db, principal.sub, "Tester");
    const stored = async () => (await handle.db.select().from(users).where(eq(users.id, principal.sub)))[0].lastBillingEnvironment;
    const held = (req: Request) => withBillingRequest(req, principal, hold, handle.db);

    expect(await held(request())).toBe("hold-rxs_production_test");
    expect(await stored()).toBeNull();
    expect(await held(request("sandbox"))).toBe("hold-rxs_sandbox_test");
    expect(await stored()).toBe("sandbox");
    expect(await held(request())).toBe("hold-rxs_sandbox_test");
    // A working production install corrects the record rather than staying pinned to sandbox.
    expect(await held(request("production"))).toBe("hold-rxs_production_test");
    expect(await held(request())).toBe("hold-rxs_production_test");
  } finally { await handle.close(); }
});

it("falls back to production for a read that arrives before the user row exists", async () => {
  const handle = await createTestDatabase();
  try {
    await withBillingRequest(request(), principal, () => fetchEntitlements(principal.sub), handle.db);
    expect(calls[0].key).toBe("rxs_production_test");
    expect(await handle.db.select().from(users)).toHaveLength(0);
  } finally { await handle.close(); }
});

function purchase(environment: string, appTransaction?: string) {
  const req = request(appTransaction);
  req.headers.set(TRANSACTION_HEADER, `signed.${environment}.purchase`);
  return req;
}

it("accepts a signed purchase as proof when the app transaction is unavailable", async () => {
  const handle = await createTestDatabase();
  try {
    await seedUser(handle.db, principal.sub, "Tester");
    expect(await withBillingRequest(purchase("sandbox"), principal, hold, handle.db)).toBe("hold-rxs_sandbox_test");
    expect(await withBillingRequest(request(), principal, hold, handle.db)).toBe("hold-rxs_sandbox_test");
  } finally { await handle.close(); }
});

it("ignores the purchase when the app transaction is present", async () => {
  expect(await withBillingRequest(purchase("sandbox", "production"), principal, hold)).toBe("hold-rxs_production_test");
  expect(SignedDataVerifier.prototype.verifyAndDecodeTransaction).not.toHaveBeenCalled();
});

it("refuses a purchase Apple did not sign instead of falling back", async () => {
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeTransaction)
    .mockRejectedValue(new VerificationException(VerificationStatus.VERIFICATION_FAILURE));
  await expect(withBillingRequest(purchase("sandbox"), principal, hold))
    .rejects.toMatchObject({ status: 403, code: "INVALID_BILLING_ENVIRONMENT" });
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeTransaction)
    .mockRejectedValue(new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE));
  await expect(withBillingRequest(purchase("sandbox"), principal, hold)).rejects.toMatchObject({ status: 503 });
  expect(calls).toHaveLength(0);
});

it("resolves a free job's environment before its insert transaction opens", async () => {
  const handle = await createTestDatabase();
  try {
    await seedUser(handle.db, principal.sub, "Tester");
    const jobId = await withBillingRequest(request("sandbox"), principal, async () => {
      const sticker = await createSticker(handle.db, principal.sub, { title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [] });
      return createExportJob(handle.db, principal.sub, sticker.stickerId);
    }, handle.db);
    const [saved] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, jobId));
    expect(saved).toMatchObject({ billingEnvironment: "sandbox", reservationId: null });
  } finally { await handle.close(); }
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
  await expect(verifyAppBillingEnvironment(`${header}.${payload}.fake`))
    .rejects.toMatchObject({ code: "INVALID_BILLING_ENVIRONMENT" });
  expect(calls).toHaveLength(0);
});

it("accepts a proof Apple stamped with the Messages extension's bundle identifier", async () => {
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).mockImplementation(async function(this: SignedDataVerifier) {
    const config = this as unknown as { environment: Environment; bundleId: string };
    if (config.bundleId !== "app.rxlab.stickerfactory.message") throw new VerificationException(VerificationStatus.INVALID_APP_IDENTIFIER);
    if (config.environment !== Environment.PRODUCTION) throw new VerificationException(VerificationStatus.INVALID_ENVIRONMENT);
    await Promise.resolve();
    return { receiptType: Environment.PRODUCTION };
  });
  expect(await withBillingRequest(request("production"), principal, hold)).toBe("hold-rxs_production_test");
});

// The App Clip signs in with the full app's OAuth client, so its token cannot say it is the Clip.
it("bills an App Clip proof as the full app when the Clip shares the app's OAuth client", async () => {
  vi.stubEnv("APP_CLIP_OAUTH_CLIENT_ID", "");
  const clipOnly = async function(this: SignedDataVerifier) {
    const config = this as unknown as { environment: Environment; bundleId: string };
    if (config.bundleId !== "app.rxlab.stickerfactory.Clip") throw new VerificationException(VerificationStatus.INVALID_APP_IDENTIFIER);
    if (config.environment !== Environment.SANDBOX) throw new VerificationException(VerificationStatus.INVALID_ENVIRONMENT);
    await Promise.resolve();
    return { receiptType: Environment.SANDBOX, environment: Environment.SANDBOX };
  };
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).mockImplementation(clipOnly);
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeTransaction).mockImplementation(clipOnly);
  expect(await withBillingRequest(request("sandbox"), principal, hold)).toBe("hold-rxs_sandbox_test");
  expect(await withBillingRequest(purchase("sandbox"), principal, hold)).toBe("hold-rxs_sandbox_test");
});

it("reports transient Apple verification failures without trying another balance", async () => {
  vi.mocked(SignedDataVerifier.prototype.verifyAndDecodeAppTransaction).mockRejectedValue(new VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE));
  await expect(withBillingRequest(request("sandbox"), principal, hold)).rejects.toMatchObject({ status: 503 });
  expect(calls).toHaveLength(0);
});
