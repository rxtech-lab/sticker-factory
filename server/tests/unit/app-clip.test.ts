import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { eq, sql } from "drizzle-orm";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { createPack, publishPack, unpublishPack } from "@/lib/services/packs";
import { getPublicPack } from "@/lib/services/public-packs";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { assets, generationJobs, stickers } from "@/lib/db/schema";
import { assertAppClipRoute, appClipAllowance, isAppClipClient } from "@/lib/subscription/app-clip";
import { chargeJobCredits, refundJobCredits } from "@/lib/subscription/credits";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { APP_STORE_ID, packShareURL } from "@/lib/sharing";
import { GET as association } from "@/app/.well-known/apple-app-site-association/route";

const clip: ApiPrincipal = { sub: "creator", clientId: "clip-client", scopes: [] };
let handle: Awaited<ReturnType<typeof createTestDatabase>>;
beforeEach(async () => {
  handle = await createTestDatabase();
  await seedUser(handle.db, "creator", "Mika");
  setObjectStoreForTests(new MemoryObjectStore());
  vi.stubEnv("APP_CLIP_OAUTH_CLIENT_ID", "clip-client");
});
afterEach(async () => { await handle?.close(); setObjectStoreForTests(undefined); vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

it("only exposes public pack metadata and published artwork", async () => {
  const sticker = await seedPublishedSticker(handle.db, "creator");
  const pack = await createPack(handle.db, "creator", { title: "Shared", stickerIds: [sticker.stickerId] });
  await expect(getPublicPack(handle.db, pack.slug)).rejects.toMatchObject({ status: 404 });
  await publishPack(handle.db, "creator", pack.id);
  const result = await getPublicPack(handle.db, pack.slug);
  expect(result.stickers).toHaveLength(1);
  expect(result.stickers[0].previewURL).toBeTruthy();
  expect(result).not.toHaveProperty("isMine");
  expect(result.creator).not.toHaveProperty("isSelf");
  await handle.db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, sticker.stickerId));
  expect((await getPublicPack(handle.db, pack.slug)).stickers).toHaveLength(0);
  await unpublishPack(handle.db, "creator", pack.id);
  // Existing marketplace unpublish semantics keep unlisted links reachable.
  const { stickerPacks } = await import("@/lib/db/schema");
  await handle.db.update(stickerPacks).set({ state: "removed" }).where(eq(stickerPacks.id, pack.id));
  await expect(getPublicPack(handle.db, pack.slug)).rejects.toMatchObject({ status: 404 });
});

it("gates Clip operations from verified identity and blocks ordinary export/retry/billing paths", () => {
  expect(isAppClipClient(clip)).toBe(true);
  expect(isAppClipClient({ clientId: "full-app" })).toBe(false);
  for (const path of ["/api/v1/stickers/a/publish", "/api/v1/stickers/a/exports", "/api/v1/stickers/a/chat/messages/b/retry", "/api/v1/packs"]) {
    expect(() => assertAppClipRoute(new Request(`https://sticker.rxlab.app${path}`, { method: "POST" }), clip)).toThrow();
  }
  expect(() => assertAppClipRoute(new Request("https://sticker.rxlab.app/api/v1/stickers", { method: "POST" }), clip)).not.toThrow();
  for (const path of ["/api/v1/stickers", "/api/v1/stickers/a/playback"]) {
    expect(() => assertAppClipRoute(new Request(`https://sticker.rxlab.app${path}`), clip)).not.toThrow();
  }
  expect(() => assertAppClipRoute(new Request("https://sticker.rxlab.app/api/v1/stickers/a/exports"), clip)).toThrow();
});

function billing(planKey = "free") {
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.example.test");
  vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "test-server-key");
  const calls: { path: string; body: Record<string, unknown> }[] = [];
  const fetch = vi.fn(async (url: URL | string, init?: RequestInit) => {
    const path = new URL(String(url)).pathname;
    calls.push({ path, body: init?.body ? JSON.parse(String(init.body)) : {} });
    return Response.json(path.endsWith("/usage")
      ? { allowed: true, used: 1, limit: 5, remaining: 4, chargedUnits: 0, duplicate: false, periodEnd: "2026-09-08T00:00:00Z" }
      : path.endsWith("/entitlements") ? { plans: [{ planKey, planName: planKey, status: "active", billingProvider: planKey === "free" ? "internal" : "apple_app_store" }], usage: [{ key: "quick_mode_allowance", used: 1, remaining: 4, limit: 5, resetsAt: "2026-09-08T00:00:00Z" }] }
      : path.endsWith("/balances/reserve") ? { reservationId: "points-1" }
      : path.endsWith("/settle") ? { operationShortfallAmount: 0 } : {});
  });
  vi.stubGlobal("fetch", fetch);
  return { calls, fetch };
}
async function createClipTurn() {
  const sticker = await createSticker(handle.db, "creator", { title: "Corgi", kind: "static", prompt: "Corgi", referenceAssetIds: [] });
  return createChatTurn(handle.db, "creator", sticker.stickerId,
    { text: "Corgi", intent: "generate", quick: true, useQuickModeAllowance: true, attachments: [], imagePlacement: "replace" });
}

it("records a free-plan attempt through the existing usage API without touching points", async () => {
  const { calls } = billing();
  const turn = await createClipTurn();
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  expect(job).toMatchObject({ appClip: true, usageReservationId: null, reservationId: null });
  await chargeJobCredits(handle.db, job);
  expect(calls.map(c => c.path)).toEqual(["/api/v1/entitlements", "/api/v1/usage"]);
  expect(calls.find(call => call.path.endsWith("/usage"))?.body.item).toBe("quick_mode_allowance");
});

it("keeps the recorded attempt on failure without calling unsupported usage refund routes", async () => {
  const { calls } = billing();
  const turn = await createClipTurn();
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  await refundJobCredits(handle.db, job, "generation_failed");
  expect(calls.map(call => call.path)).toEqual(["/api/v1/entitlements", "/api/v1/usage"]);
});

it("fails closed on missing usage configuration or exhausted allowance", async () => {
  await expect(createClipTurn()).rejects.toMatchObject({ status: 503 });
  const { fetch } = billing();
  const respond = fetch.getMockImplementation()!;
  fetch.mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/usage")
    ? Response.json({ allowed: false }, { status: 402 }) : respond(url, init));
  await expect(createClipTurn()).rejects.toMatchObject({ status: 402, code: "APP_CLIP_LIMIT_REACHED" });
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
});

it("serves the correct App Clip association and App Store destination", async () => {
  const result = await (await association()).json();
  expect(result.appclips.apps).toContain("T7GYB573Y6.app.rxlab.stickerfactory.Clip");
  expect(APP_STORE_ID).toBe("6805825708");
  expect(packShareURL("hello-pack")).toBe("https://sticker.rxlab.app/share/ios/packs/hello-pack");
});


it("runs generation and publication as one free operation, including revisions", async () => {
  const { setDatabaseForTests } = await import("@/lib/db/client");
  const { setAiProviderForTests } = await import("@/lib/ai/gateway");
  const { stickerGenerationWorkflow } = await import("@/workflows/sticker-generation");
  const { calls } = billing();
  vi.stubEnv("STICKER_FACTORY_MOCK_SERVICES", "true");
  setDatabaseForTests(handle.db);
  setAiProviderForTests(undefined);
  try {
    const turn = await createClipTurn();
    expect((await stickerGenerationWorkflow(turn.jobId, true, true)).workflowStatus).toBe("succeeded");
    const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
    const [sticker] = await handle.db.select().from(stickers).where(eq(stickers.id, job.stickerId));
    expect(sticker.status).toBe("published");
    expect(job.usageReservationId).toBeNull();
    const revise = await createChatTurn(handle.db, "creator", sticker.id,
      { text: "Make it wave", intent: "edit", attachments: [], imagePlacement: "replace", quick: true, useQuickModeAllowance: true });
    expect((await stickerGenerationWorkflow(revise.jobId, true, true)).workflowStatus).toBe("succeeded");
    expect(calls.filter(call => call.path.endsWith("/usage"))).toHaveLength(2);
    // No points are held or charged. The only balance moved is the owner's pet gold for the sticker.
    expect(calls.filter(call => call.path.includes("balances"))
      .every(call => call.path === "/api/v1/balances" && (!call.body.unit || call.body.unit === "gold"))).toBe(true);
  } finally { setDatabaseForTests(undefined); setAiProviderForTests(undefined); }
});

it("allows the shared main-app identity to read its quick-mode plan allowance", async () => {
  billing();
  const handler = await import("@/lib/http/handler");
  vi.spyOn(handler, "withApiAuth").mockImplementation(async (_request, action) =>
    action({ ...clip, clientId: "full-app" }, handle.db, {} as never));
  const { GET } = await import("@/app/api/v1/app-clip/allowance/route");
  const response = await GET(new Request("https://sticker.rxlab.app/api/v1/app-clip/allowance"));
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ key: "quick_mode_allowance", limit: 5, remaining: 4 });
});

it("routes a shared-client quick request to the existing usage API", async () => {
  const { calls } = billing();
  const handler = await import("@/lib/http/handler");
  const workflows = await import("@/lib/services/workflows");
  vi.spyOn(handler, "withApiAuth").mockImplementation(async (_request, action) =>
    action({ ...clip, clientId: "full-app" }, handle.db, {} as never));
  vi.spyOn(workflows, "startGenerationWorkflow").mockResolvedValue("run-quick");
  const { POST } = await import("@/app/api/v1/stickers/route");
  const response = await POST(new Request("https://sticker.rxlab.app/api/v1/stickers", {
    method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": "shared-client-quick" },
    body: JSON.stringify({ title: "Cat", prompt: "Cat", kind: "static", quick: true, useQuickModeAllowance: true }),
  }));
  expect(response.status).toBe(202);
  expect(calls.map(call => call.path)).toEqual(["/api/v1/entitlements", "/api/v1/usage"]);
  expect(calls.find(call => call.path.endsWith("/usage"))?.body.item).toBe("quick_mode_allowance");
});

it("rejects rich operations requesting the quick allowance before spending usage", async () => {
  const { calls } = billing();
  const sticker = await createSticker(handle.db, "creator", { title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [] });
  for (const fields of [{ quick: false }, { intent: "chat" as const }, { targetLayerId: "layer" }]) {
    await expect(createChatTurn(handle.db, "creator", sticker.stickerId, {
      text: "Cat", intent: "generate", quick: true, useQuickModeAllowance: true,
      attachments: [], imagePlacement: "replace", ...fields,
    })).rejects.toMatchObject({ status: 422, code: "APP_CLIP_QUICK_ONLY" });
  }
  expect(calls).toHaveLength(0);
});

it("reports a missing reconciliation column before the usage-service lookup", async () => {
  const { fetch } = billing();
  await handle.db.execute(sql`ALTER TABLE generation_jobs DROP COLUMN app_clip`);
  const handler = await import("@/lib/http/handler");
  const log = vi.fn();
  vi.spyOn(handler, "withApiAuth").mockImplementation(async (_request, action) =>
    action(clip, handle.db, { requestId: "test", method: "GET", path: "/api/v1/app-clip/allowance", log }));
  const { GET } = await import("@/app/api/v1/app-clip/allowance/route");
  await expect(GET(new Request("https://sticker.rxlab.app/api/v1/app-clip/allowance")))
    .rejects.toMatchObject({ status: 503, code: "APP_CLIP_SCHEMA_NOT_READY" });
  expect(fetch).not.toHaveBeenCalled();
  expect(log).toHaveBeenCalledWith("app_clip_allowance_failed", {
    causes: expect.arrayContaining([expect.objectContaining({ code: "42703" })]),
  });
  expect(JSON.stringify(log.mock.calls)).not.toContain("SELECT");
});

it("reads the count from usage service and logs upstream failures without response data", async () => {
  const { fetch } = billing();
  fetch.mockResolvedValueOnce(Response.json({ plans: [{ planKey: "free" }], usage: [
    { key: "unrelated_gauge", used: 1.5 },
    { key: "quick_mode_allowance", limit: 12, used: 3, remaining: 9, resetsAt: null },
  ] }));
  expect(await appClipAllowance(handle.db, "creator")).toMatchObject({ limit: 12, remaining: 9 });
  fetch.mockResolvedValueOnce(Response.json({ error: "scope_denied", error_description: "sensitive upstream details" }, { status: 403 }));
  const handler = await import("@/lib/http/handler");
  const log = vi.fn();
  vi.spyOn(handler, "withApiAuth").mockImplementation(async (_request, action) =>
    action(clip, handle.db, { requestId: "test", method: "GET", path: "/api/v1/app-clip/allowance", log }));
  const { GET } = await import("@/app/api/v1/app-clip/allowance/route");
  await expect(GET(new Request("https://sticker.rxlab.app/api/v1/app-clip/allowance")))
    .rejects.toMatchObject({ status: 503, code: "APP_CLIP_USAGE_UNAVAILABLE" });
  expect(log).toHaveBeenCalledWith("app_clip_allowance_failed", {
    causes: [expect.objectContaining({ code: "scope_denied", status: 403 })],
  });
  expect(JSON.stringify(log.mock.calls)).not.toContain("sensitive upstream details");
});


it("charges paid quick generation as well as consuming its backend allowance", async () => {
  const { calls } = billing("pro");
  const turn = await createClipTurn();
  await handle.db.update(generationJobs).set({ apiImagePoints: 3 }).where(eq(generationJobs.id, turn.jobId));
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  expect(job).toMatchObject({ usageReservationId: null, reservationId: "points-1", reservationAmount: 10 });
  await chargeJobCredits(handle.db, job);
  expect(calls.find(call => call.path.endsWith("/settle"))?.body).toMatchObject({ amount: 3, final: true });
  expect(calls.filter(call => call.path.endsWith("/usage"))).toHaveLength(1);
  expect((await handle.db.select().from(generationJobs))[0]).toMatchObject({ usageReservationId: null, reservationId: null });
  expect(await appClipAllowance(handle.db, "creator")).toMatchObject({ chargesPoints: true, limit: 5 });
});

it("releases points for a failed paid quick generation without reversing its attempt count", async () => {
  const { calls } = billing("pro");
  const turn = await createClipTurn();
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  await refundJobCredits(handle.db, job, "generation_failed");
  expect(calls.filter(call => call.path.endsWith("/release")).map(call => call.path)).toEqual([
    "/api/v1/balances/reservations/points-1/release",
  ]);
});

it("does not consume usage if the paid account has insufficient points", async () => {
  const { fetch, calls } = billing("pro");
  const respond = fetch.getMockImplementation()!;
  fetch.mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/balances/reserve")
    ? Response.json({ error: "insufficient_balance", available: 0, required: 10 }, { status: 402 })
    : respond(url, init));
  await expect(createClipTurn()).rejects.toMatchObject({ code: "INSUFFICIENT_CREDITS", status: 402 });
  expect(calls.some(call => call.path.endsWith("/usage"))).toBe(false);
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
});

it("does not interpret absent or inconsistent allowance data as unlimited", async () => {
  const { fetch } = billing();
  for (const item of [
    { key: "quick_mode_allowance", used: 0, resetsAt: null },
    { key: "quick_mode_allowance", used: 0, limit: 5, remaining: null, resetsAt: null },
  ]) {
    fetch.mockImplementation(async () => Response.json({ plans: [{ planKey: "free" }], usage: [item] }));
    await expect(appClipAllowance(handle.db, "creator")).rejects.toMatchObject({ status: 503 });
    await expect(createClipTurn()).rejects.toMatchObject({ status: 503 });
  }
});

it("preserves explicitly unlimited backend usage without waiving paid points", async () => {
  const { fetch } = billing("pro");
  fetch.mockResolvedValueOnce(Response.json({ plans: [{ planKey: "pro" }], usage: [
    { key: "quick_mode_allowance", used: 3, limit: null, remaining: null, resetsAt: null },
  ] }));
  expect(await appClipAllowance(handle.db, "creator")).toMatchObject({ limit: null, remaining: null, chargesPoints: true });
});


it("reconciles paid point settlement without recording usage again", async () => {
  const { fetch, calls } = billing("pro");
  const turn = await createClipTurn();
  await handle.db.update(generationJobs).set({ state: "succeeded", apiImagePoints: 3 }).where(eq(generationJobs.id, turn.jobId));
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  const respond = fetch.getMockImplementation()!;
  fetch.mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/settle")
    ? Response.json({ error: "unavailable" }, { status: 503 }) : respond(url, init));
  await chargeJobCredits(handle.db, job);
  expect((await handle.db.select().from(generationJobs))[0]).toMatchObject({ usageReservationId: null, reservationId: "points-1" });
  fetch.mockImplementation(respond);
  await appClipAllowance(handle.db, "creator");
  expect((await handle.db.select().from(generationJobs))[0].reservationId).toBeNull();
  expect(calls.filter(call => call.path.endsWith("/usage"))).toHaveLength(1);
});

it("releases the point hold when the backend rejects usage", async () => {
  const { fetch, calls } = billing("pro");
  const respond = fetch.getMockImplementation()!;
  fetch.mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/usage")
    ? Response.json({ allowed: false }, { status: 402 }) : respond(url, init));
  await expect(createClipTurn()).rejects.toMatchObject({ status: 402, code: "APP_CLIP_LIMIT_REACHED" });
  expect(calls.filter(call => call.path.includes("balances")).map(call => call.path)).toEqual([
    "/api/v1/balances/reserve", "/api/v1/balances/reservations/points-1/release",
  ]);
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
});

it.each([false, true])("can retry the same creation request after a missing usage endpoint rejects it (reference: %s)", async (withReference) => {
  const { fetch } = billing();
  const respond = fetch.getMockImplementation()!;
  let unavailable = true;
  fetch.mockImplementation(async (url, init) => unavailable && new URL(String(url)).pathname.endsWith("/usage")
    ? new Response("Not Found", { status: 404 }) : respond(url, init));
  const handler = await import("@/lib/http/handler");
  const workflows = await import("@/lib/services/workflows");
  vi.spyOn(handler, "withApiAuth").mockImplementation(async (_request, action) =>
    action({ ...clip, clientId: "full-app" }, handle.db, {} as never));
  vi.spyOn(workflows, "startGenerationWorkflow").mockResolvedValue("recovered-run");
  const { POST } = await import("@/app/api/v1/stickers/route");
  const referenceID = crypto.randomUUID();
  if (withReference) await handle.db.insert(assets).values({
    id: referenceID, ownerId: "creator", kind: "reference", state: "ready",
    r2Key: `reference/${referenceID}`, mimeType: "image/png", byteSize: 100, width: 128, height: 128,
  });
  const request = () => new Request("https://sticker.rxlab.app/api/v1/stickers", {
    method: "POST", headers: { "Content-Type": "application/json", "Idempotency-Key": "retry-missing-usage-route" },
    body: JSON.stringify({ title: "Cat", prompt: "Cat", kind: "static", quick: true, useQuickModeAllowance: true, referenceAssetIds: withReference ? [referenceID] : [] }),
  });
  await expect(POST(request())).rejects.toMatchObject({ status: 503 });
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
  if (withReference) expect((await handle.db.select().from(assets).where(eq(assets.id, referenceID)))[0]).toMatchObject({ state: "ready", stickerId: null });
  unavailable = false;
  const response = await POST(request());
  expect(response.status).toBe(202);
  expect(await handle.db.select().from(generationJobs)).toHaveLength(1);
  expect((await POST(request())).headers.get("idempotency-replayed")).toBe("true");
  expect(await handle.db.select().from(generationJobs)).toHaveLength(1);
});


it("never calls usage reservation routes when the service only supports POST /usage", async () => {
  const { fetch, calls } = billing("pro");
  const respond = fetch.getMockImplementation()!;
  fetch.mockImplementation(async (url, init) => new URL(String(url)).pathname.includes("/usage/")
    ? new Response("Not Found", { status: 404 }) : respond(url, init));
  const turn = await createClipTurn();
  const [job] = await handle.db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId));
  await chargeJobCredits(handle.db, job);
  const usage = calls.filter(call => call.path.endsWith("/usage"));
  expect(usage).toHaveLength(1);
  expect(usage[0].body).toMatchObject({ rxlabUserId: "creator", item: "quick_mode_allowance", amount: 1, idempotencyKey: turn.jobId });
  expect(calls.some(call => call.path.includes("/usage/"))).toBe(false);
});
