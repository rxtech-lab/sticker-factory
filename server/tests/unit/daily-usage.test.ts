import { eq } from "drizzle-orm";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { assets, chatMessages, generationJobs, plans } from "@/lib/db/schema";
import { cancelPlan, confirmPlan, createPlan, finalizePlan } from "@/lib/services/plans";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { retryFailedChatTurn } from "@/lib/services/sticker-chat";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedUser } from "@/tests/helpers/packs";

const GENERATION = "daily_sticker_generation";
const REFINEMENT = "daily_sticker_refinement";

let handle: Awaited<ReturnType<typeof createTestDatabase>>;
beforeEach(async () => {
  handle = await createTestDatabase();
  await seedUser(handle.db, "creator", "Mika");
});
afterEach(async () => { await handle?.close(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

type Call = { method: string; path: string; body: Record<string, unknown> };
const allowance = (key: string, remaining: number | null = 4) =>
  ({ key, used: 1, remaining, limit: remaining === null ? null : 5, resetsAt: "2026-09-22T00:00:00Z" });

/** Billing on, with every item allowed unless a test says otherwise. */
function billing(options: { usage?: unknown[]; refuse?: string[] } = {}) {
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.example.test");
  vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "test-server-key");
  const calls: Call[] = [];
  vi.stubGlobal("fetch", vi.fn(async (url: URL | string, init?: RequestInit) => {
    const path = new URL(String(url)).pathname;
    const body = init?.body ? JSON.parse(String(init.body)) : {};
    calls.push({ method: init?.method ?? "GET", path, body });
    if (path.endsWith("/usage")) return Response.json({ allowed: !options.refuse?.includes(body.item) });
    if (path.endsWith("/entitlements")) {
      return Response.json({
        plans: [{ planKey: "pro", planName: "Pro", status: "active", billingProvider: "apple_app_store" }],
        usage: options.usage ?? [allowance("quick_mode_allowance"), allowance(GENERATION), allowance(REFINEMENT)],
      });
    }
    return Response.json(path.endsWith("/balances/reserve") ? { reservationId: "points-1" } : {});
  }));
  const recorded = () => calls.filter(call => call.path.endsWith("/usage")).map(call => call.body);
  const released = () => calls.some(call => call.path.endsWith("/release"));
  return { calls, recorded, released };
}

const message = (text: string) => ({ text, intent: "generate" as const, attachments: [], imagePlacement: "replace" as const });
const newSticker = (kind: "static" | "animated" = "static") =>
  createSticker(handle.db, "creator", { title: "Corgi", kind, prompt: "Corgi", referenceAssetIds: [] });
const settleTurns = (stickerId: string) => handle.db.update(generationJobs)
  .set({ state: "succeeded", completedAt: new Date() }).where(eq(generationJobs.stickerId, stickerId));

it("spends a sticker and a message on a new sticker, and only a message on a follow-up", async () => {
  const { recorded } = billing();
  const sticker = await newSticker();
  const first = await createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true);
  expect(recorded()).toEqual([
    expect.objectContaining({ rxlabUserId: "creator", item: GENERATION, amount: 1, idempotencyKey: `${GENERATION}:${first.jobId}` }),
    expect.objectContaining({ rxlabUserId: "creator", item: REFINEMENT, amount: 1, idempotencyKey: `${REFINEMENT}:${first.jobId}` }),
  ]);
  await settleTurns(sticker.stickerId);
  const second = await createChatTurn(handle.db, "creator", sticker.stickerId, message("Add a hat"));
  expect(recorded().slice(2)).toEqual([
    expect.objectContaining({ item: REFINEMENT, idempotencyKey: `${REFINEMENT}:${second.jobId}` }),
  ]);
});

it("rejects a message past the daily limit, releases the point hold, and stores nothing", async () => {
  const { released } = billing({ refuse: [REFINEMENT] });
  const sticker = await newSticker();
  await expect(createChatTurn(handle.db, "creator", sticker.stickerId, message("Add a hat")))
    .rejects.toMatchObject({ status: 402, code: "DAILY_LIMIT_REACHED", details: { item: REFINEMENT } });
  expect(released()).toBe(true);
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
  expect(await handle.db.select().from(chatMessages)).toHaveLength(0);
});

it("maps an upstream 402 to the daily limit", async () => {
  const { calls } = billing();
  const respond = vi.mocked(fetch).getMockImplementation()!;
  vi.mocked(fetch).mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/usage")
    ? Response.json({ error: "usage_limit_exceeded" }, { status: 402 }) : respond(url, init));
  const sticker = await newSticker();
  await expect(createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true))
    .rejects.toMatchObject({ status: 402, code: "DAILY_LIMIT_REACHED", details: { item: GENERATION } });
  expect(calls.some(call => call.path.endsWith("/release"))).toBe(true);
});

it("does not spend a sticker when the day's messages are already used", async () => {
  const { recorded } = billing({ usage: [allowance(GENERATION), allowance(REFINEMENT, 0)] });
  const sticker = await newSticker();
  await expect(createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true))
    .rejects.toMatchObject({ status: 402, code: "DAILY_LIMIT_REACHED", details: { item: REFINEMENT } });
  expect(recorded()).toEqual([]);
});

it("treats an explicit null limit as unlimited", async () => {
  const { recorded } = billing({ usage: [allowance(GENERATION, null), allowance(REFINEMENT, null)] });
  const sticker = await newSticker();
  await createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true);
  expect(recorded().map(body => body.item)).toEqual([GENERATION, REFINEMENT]);
});

it("fails closed when an allowance is missing, malformed, or unreachable", async () => {
  const sticker = await newSticker();
  const create = () => createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true);

  let mock = billing({ usage: [allowance(GENERATION)] });
  await expect(create()).rejects.toMatchObject({ status: 503, code: "DAILY_USAGE_NOT_CONFIGURED" });
  expect(mock.recorded()).toEqual([]);

  mock = billing({ usage: [allowance(GENERATION), { key: REFINEMENT, limit: 5, remaining: null }] });
  await expect(create()).rejects.toMatchObject({ status: 503, code: "DAILY_USAGE_UNAVAILABLE" });
  expect(mock.recorded()).toEqual([]);

  billing();
  const respond = vi.mocked(fetch).getMockImplementation()!;
  vi.mocked(fetch).mockImplementation(async (url, init) => new URL(String(url)).pathname.endsWith("/usage")
    ? Response.json({ error: "not_found" }, { status: 404 }) : respond(url, init));
  await expect(createChatTurn(handle.db, "creator", sticker.stickerId, message("Add a hat")))
    .rejects.toMatchObject({ status: 503, code: "DAILY_USAGE_NOT_CONFIGURED" });

  vi.mocked(fetch).mockImplementation(async (url, init) => {
    if (new URL(String(url)).pathname.endsWith("/usage")) throw new Error("socket hang up");
    return respond(url, init);
  });
  await expect(createChatTurn(handle.db, "creator", sticker.stickerId, message("Add a hat")))
    .rejects.toMatchObject({ status: 503, code: "DAILY_USAGE_UNAVAILABLE" });
  expect(await handle.db.select().from(generationJobs)).toHaveLength(0);
});

it("leaves quick-mode turns on their own allowance", async () => {
  const { recorded } = billing();
  const sticker = await newSticker();
  await createChatTurn(handle.db, "creator", sticker.stickerId,
    { ...message("Corgi"), quick: true, useQuickModeAllowance: true }, false, true);
  expect(recorded().map(body => body.item)).toEqual(["quick_mode_allowance"]);
});

it("meters nothing when billing is not configured", async () => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  const sticker = await newSticker();
  await createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true);
  expect(fetch).not.toHaveBeenCalled();
});

it("does not count a retry, which reuses the message already counted", async () => {
  const sticker = await newSticker();
  const turn = await createChatTurn(handle.db, "creator", sticker.stickerId, message("Corgi"), false, true);
  await handle.db.update(generationJobs).set({ state: "failed" }).where(eq(generationJobs.id, turn.jobId));
  await handle.db.update(chatMessages).set({ status: "failed" }).where(eq(chatMessages.id, turn.messageId));
  const { recorded } = billing();
  await retryFailedChatTurn(handle.db, "creator", sticker.stickerId, turn.messageId);
  expect(recorded()).toEqual([]);
});

/** A finalized animated plan with its static reference, the state a user can act on. */
async function actionablePlan() {
  const sticker = await newSticker("animated");
  const turn = await createChatTurn(handle.db, "creator", sticker.stickerId,
    { text: "Plan it", intent: "chat", attachments: [], imagePlacement: "replace" });
  const created = await createPlan(handle.db, {
    ownerId: "creator", stickerId: sticker.stickerId, threadId: sticker.threadId, messageId: turn.messageId,
    plan: PlanV1Schema.parse({
      version: 1, title: "Hello", summary: "Hello summary.", kind: "animated",
      timing: { durationSeconds: 2, fps: 30, loop: "loop" },
      layers: [{ layerId: "part", name: "Part", source: { kind: "generate", prompt: "A corgi" }, x: 0.5, y: 0.5, scaleX: 0.4, scaleY: 0.4 }],
    }),
  });
  await finalizePlan(handle.db, { ownerId: "creator", stickerId: sticker.stickerId, planId: created.planId });
  const reference = `reference-${created.planId}`;
  await handle.db.insert(assets).values({
    id: reference, ownerId: "creator", stickerId: sticker.stickerId, kind: "reference",
    state: "ready", r2Key: reference, mimeType: "image/png",
  });
  await handle.db.update(plans).set({ conceptAssetId: reference, animationPreviewAssetId: reference })
    .where(eq(plans.id, created.planId));
  await settleTurns(sticker.stickerId);
  return { stickerId: sticker.stickerId, planId: created.planId };
}

it("counts confirming a plan and rejecting one with a reason, but not a plain dismissal", async () => {
  const confirmed = await actionablePlan();
  let mock = billing();
  const build = await confirmPlan(handle.db, "creator", confirmed.stickerId, confirmed.planId);
  expect(mock.recorded()).toEqual([
    expect.objectContaining({ item: REFINEMENT, idempotencyKey: `${REFINEMENT}:${build.jobId}` }),
  ]);

  vi.unstubAllEnvs(); vi.unstubAllGlobals();
  const rejected = await actionablePlan();
  mock = billing();
  const redraft = await cancelPlan(handle.db, "creator", rejected.stickerId, rejected.planId, "Too cramped");
  expect(mock.recorded()).toEqual([
    expect.objectContaining({ item: REFINEMENT, idempotencyKey: `${REFINEMENT}:${redraft.jobId}` }),
  ]);

  vi.unstubAllEnvs(); vi.unstubAllGlobals();
  const dismissed = await actionablePlan();
  mock = billing();
  await cancelPlan(handle.db, "creator", dismissed.stickerId, dismissed.planId);
  expect(mock.recorded()).toEqual([]);
});

it("leaves a plan actionable when the daily limit refuses the turn", async () => {
  const { stickerId, planId } = await actionablePlan();
  const { released } = billing({ refuse: [REFINEMENT] });
  await expect(confirmPlan(handle.db, "creator", stickerId, planId))
    .rejects.toMatchObject({ status: 402, code: "DAILY_LIMIT_REACHED" });
  await expect(cancelPlan(handle.db, "creator", stickerId, planId, "Too cramped"))
    .rejects.toMatchObject({ status: 402, code: "DAILY_LIMIT_REACHED" });
  expect(released()).toBe(true);
  const [plan] = await handle.db.select().from(plans).where(eq(plans.id, planId));
  expect(plan.state).toBe("finalized");
});
