import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/lib/http/errors";
import {
  abandonHold,
  chargeJobCredits,
  finalizeJobCredits,
  holdCreditsForJob,
  refundJobCredits,
  requirePermission,
} from "@/lib/subscription/credits";
import { subscriptionEnabled } from "@/lib/subscription/config";
import { composeCreditHold, exportCreditCost, jobCreditHold } from "@/lib/subscription/pricing";
import { PlanV1Schema } from "@/lib/contracts/plan";
import type { GenerationJobRow } from "@/lib/db/schema";
import type { PublishExportsRequest } from "@/lib/contracts/api";

/** Records every outbound call so a test can assert what the billing service was asked to do. */
interface Call {
  method: string;
  path: string;
  body: Record<string, unknown> | null;
}

let calls: Call[] = [];
let respond: (call: Call) => { status: number; body: unknown };

function stubFetch() {
  vi.stubGlobal("fetch", async (input: URL | string, init?: RequestInit) => {
    const url = new URL(String(input));
    const call: Call = {
      method: init?.method ?? "GET",
      path: url.pathname,
      body: init?.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : null,
    };
    calls.push(call);
    const { status, body } = respond(call);
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  });
}

/** A `db` that only has to absorb the `update().set().where()` that clears a closed hold. */
function fakeDb() {
  const cleared: string[] = [];
  const db = {
    update: () => ({ set: () => ({ where: async () => { cleared.push("cleared"); } }) }),
  };
  return { db: db as never, cleared };
}

function job(overrides: Partial<GenerationJobRow> = {}): GenerationJobRow {
  return {
    id: "job-1",
    ownerId: "user-1",
    stickerId: "sticker-1",
    sourceMessageId: null,
    kind: "image",
    priorStickerStatus: null,
    state: "running",
    workflowRunId: null,
    reservationId: "res-1",
    reservationAmount: 10,
    apiTextCostNanodollars: 100_000_000,
    apiImageCostNanodollars: 20_000_000,
    apiImagePoints: 2,
    apiVideoCostNanodollars: 0,
    apiVideoPoints: 0,
    attempts: 1,
    errorCode: null,
    errorMessage: null,
    createdAt: new Date(0),
    updatedAt: new Date(0),
    completedAt: null,
    ...overrides,
  } as GenerationJobRow;
}

beforeEach(() => {
  calls = [];
  respond = () => ({ status: 200, body: {} });
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://billing.example.test");
  vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_test");
  stubFetch();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("when billing is unconfigured", () => {
  beforeEach(() => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", "");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "");
  });

  it("reports itself as off", () => {
    expect(subscriptionEnabled()).toBe(false);
  });

  it("lets a generation through without holding anything", async () => {
    await expect(
      holdCreditsForJob({
        ownerId: "user-1",
        amount: 10,
        idempotencyKey: "reserve:job-1",
        description: "Sticker generate",
      }),
    ).resolves.toBeNull();
    expect(calls).toHaveLength(0);
  });


});

describe("holdCreditsForJob", () => {
  it("reserves the job's cost and returns the hold id", async () => {
    respond = () => ({
      status: 200,
      body: {
        reservationId: "res-9",
        amount: 10,
        available: 90,
        expiresAt: new Date(60_000).toISOString(),
        status: "open",
        duplicate: false,
      },
    });

    const reservationId = await holdCreditsForJob({
      ownerId: "user-1",
      amount: 10,
      idempotencyKey: "reserve:job-1",
      description: "Sticker generate",
      metadata: { jobId: "job-1" },
    });

    expect(reservationId).toBe("res-9");
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ method: "POST", path: "/api/v1/balances/reserve" });
    expect(calls[0].body).toMatchObject({
      rxlabUserId: "user-1",
      unit: "points",
      amount: 10,
      idempotencyKey: "reserve:job-1",
    });
  });

  it("holds nothing for a free job, and does not call out at all", async () => {
    await expect(
      holdCreditsForJob({
        ownerId: "user-1",
        amount: 0,
        idempotencyKey: "reserve:job-1",
        description: "Sticker chat",
      }),
    ).resolves.toBeNull();
    expect(calls).toHaveLength(0);
  });

  it("turns an unaffordable job into a 402 the client can show a paywall for", async () => {
    respond = () => ({
      status: 409,
      body: { error: "insufficient_balance", available: 3, required: 10 },
    });

    const error = await holdCreditsForJob({
      ownerId: "user-1",
      amount: 10,
      idempotencyKey: "reserve:job-1",
      description: "Sticker generate",
    }).catch((thrown: unknown) => thrown);

    expect(error).toBeInstanceOf(ApiError);
    const apiError = error as ApiError;
    expect(apiError.status).toBe(402);
    expect(apiError.code).toBe("INSUFFICIENT_CREDITS");
    expect(apiError.details).toMatchObject({ available: 3, required: 10, unit: "points" });
  });

  it("does not read a billing outage as an empty wallet", async () => {
    respond = () => ({ status: 500, body: { error: "server_error" } });

    const error = await holdCreditsForJob({
      ownerId: "user-1",
      amount: 10,
      idempotencyKey: "reserve:job-1",
      description: "Sticker generate",
    }).catch((thrown: unknown) => thrown);

    expect(error).toBeInstanceOf(ApiError);
    expect((error as ApiError).status).toBe(503);
    expect((error as ApiError).code).toBe("SUBSCRIPTION_UNAVAILABLE");
  });

  it("reports an unreachable billing service rather than hanging the request", async () => {
    vi.stubGlobal("fetch", async () => {
      throw new TypeError("fetch failed");
    });

    const error = await holdCreditsForJob({
      ownerId: "user-1",
      amount: 10,
      idempotencyKey: "reserve:job-1",
      description: "Sticker generate",
    }).catch((thrown: unknown) => thrown);

    expect((error as ApiError).code).toBe("SUBSCRIPTION_UNAVAILABLE");
  });
});

describe("settling and releasing", () => {
  it("settles the exact API-priced amount and releases the rest when a job succeeds", async () => {
    const { db, cleared } = fakeDb();
    await chargeJobCredits(db, job());

    expect(calls).toHaveLength(1);
    expect(calls[0].path).toBe("/api/v1/balances/reservations/res-1/settle");
    // $0.10 text = 7 points, plus 2 already-rounded image points.
    expect(calls[0].body).toMatchObject({
      amount: 9,
      final: true,
      idempotencyKey: "settle:job-1",
      metadata: {
        textCostNanodollars: 100_000_000,
        imageCostNanodollars: 20_000_000,
        imagePoints: 2,
        videoCostNanodollars: 0,
        videoPoints: 0,
        chargedPoints: 9,
      },
    });
    expect(cleared).toHaveLength(1);
  });

  it("charges a clip's points on top of the text and image ones", async () => {
    const { db } = fakeDb();
    await chargeJobCredits(db, job({ kind: "compose", apiVideoCostNanodollars: 29_100_000, apiVideoPoints: 3 }));
    expect(calls[0].body).toMatchObject({
      amount: 12,
      metadata: { videoCostNanodollars: 29_100_000, videoPoints: 3, chargedPoints: 12 },
    });
  });

  it("keeps fixed-price non-AI export charging", async () => {
    const { db } = fakeDb();
    await chargeJobCredits(db, job({
      kind: "export",
      apiTextCostNanodollars: 0,
      apiImageCostNanodollars: 0,
      apiImagePoints: 0,
    }));

    expect(calls[0].body).toMatchObject({ amount: 10, final: true });
  });

  it("returns the hold when a job fails", async () => {
    const { db, cleared } = fakeDb();
    await refundJobCredits(db, job(), "generation_failed");

    expect(calls[0].path).toBe("/api/v1/balances/reservations/res-1/release");
    expect(calls[0].body).toMatchObject({
      idempotencyKey: "release:job-1",
      reason: "generation_failed",
    });
    expect(cleared).toHaveLength(1);
  });

  it("routes each ending to the right side of the ledger", async () => {
    const { db } = fakeDb();
    await finalizeJobCredits(db, job(), "succeeded");
    await finalizeJobCredits(db, job(), "failed");
    await finalizeJobCredits(db, job(), "cancelled");

    expect(calls.map((call) => call.path.split("/").pop())).toEqual([
      "settle",
      "release",
      "release",
    ]);
    expect(calls[2].body).toMatchObject({ reason: "user_cancelled" });
  });

  it("does nothing for a job that never held credits", async () => {
    const { db, cleared } = fakeDb();
    await chargeJobCredits(db, job({ reservationId: null, reservationAmount: 0 }));
    await refundJobCredits(db, job({ reservationId: null, reservationAmount: 0 }), "cancelled");

    expect(calls).toHaveLength(0);
    expect(cleared).toHaveLength(0);
  });

  it("does not let a billing failure stop a job from being finished", async () => {
    respond = () => ({ status: 500, body: { error: "server_error" } });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { db, cleared } = fakeDb();

    await expect(chargeJobCredits(db, job())).resolves.toBeUndefined();
    await expect(refundJobCredits(db, job(), "generation_failed")).resolves.toBeUndefined();

    expect(errors).toHaveBeenCalled();
    // The hold reference survives a failed settle, so nothing is silently
    // forgotten; the reservation's own expiry returns the credits.
    expect(cleared).toHaveLength(1);
  });

  it("releases a hold whose job never made it into the database", async () => {
    await abandonHold("res-1", "job-1", "job_not_created");
    expect(calls[0].path).toBe("/api/v1/balances/reservations/res-1/release");
  });
});

describe("requirePermission", () => {
  it("passes when the plan grants it", async () => {
    respond = () => ({ status: 200, body: { roles: ["pro"], permissions: ["marketplace.publish:all"], plans: [], balances: [] } });
    await expect(
      requirePermission("user-1", "marketplace.publish", "needs a plan"),
    ).resolves.toBeUndefined();
  });

  it("answers 402 when it does not, so the client can offer an upgrade", async () => {
    respond = () => ({ status: 200, body: { roles: ["free"], permissions: [], plans: [], balances: [] } });

    const error = await requirePermission(
      "user-1",
      "marketplace.publish",
      "Publishing packs to the marketplace needs a paid plan.",
    ).catch((thrown: unknown) => thrown);

    expect((error as ApiError).status).toBe(402);
    expect((error as ApiError).code).toBe("SUBSCRIPTION_REQUIRED");
  });

  it("fails closed when the check cannot run, rather than giving away a paid tier", async () => {
    respond = () => ({ status: 500, body: { error: "server_error" } });

    const error = await requirePermission("user-1", "marketplace.publish", "needs a plan")
      .catch((thrown: unknown) => thrown);

    expect((error as ApiError).status).toBe(503);
    expect((error as ApiError).code).toBe("SUBSCRIPTION_UNAVAILABLE");
  });
});

describe("pricing", () => {
  it("holds an estimate for every job that can call an AI API", () => {
    expect(jobCreditHold("image")).toBeGreaterThan(0);
    expect(jobCreditHold("edit")).toBeGreaterThan(0);
    expect(jobCreditHold("animation")).toBeGreaterThan(jobCreditHold("image"));
    expect(jobCreditHold("compose")).toBeGreaterThan(jobCreditHold("image"));
    expect(jobCreditHold("chat")).toBeGreaterThan(0);
    expect(jobCreditHold("plan")).toBeGreaterThan(0);
  });

  it("never charges anyone to delete their own work", () => {
    expect(jobCreditHold("cleanup")).toBe(0);
  });

  it("holds more for a plan that will generate a clip", () => {
    const layer = { layerId: "part_0", name: "Hero", x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8 };
    const drawn = PlanV1Schema.parse({
      version: 1, title: "T", summary: "Drawn.", kind: "animated",
      layers: [{ ...layer, source: { kind: "generate", prompt: "A corgi" } }],
    });
    const clipped = PlanV1Schema.parse({
      version: 1, title: "T", summary: "The corgi is a video so it can turn.", kind: "animated",
      layers: [{ ...layer, source: { kind: "video", prompt: "A corgi", motion: "turns around" } }],
    });
    expect(composeCreditHold(drawn)).toBe(jobCreditHold("compose"));
    expect(composeCreditHold(clipped)).toBeGreaterThan(jobCreditHold("compose"));
  });

  it("charges for an animated export and not for a still one", () => {
    const base = { revisionId: "r", systemAssetId: "s" } as PublishExportsRequest;
    expect(exportCreditCost(base)).toBe(0);
    expect(exportCreditCost({ ...base, pngAssetId: "p" })).toBe(0);
    expect(exportCreditCost({ ...base, mp4AssetId: "m" })).toBeGreaterThan(0);
    expect(exportCreditCost({ ...base, apngAssetId: "a" })).toBeGreaterThan(0);
  });
});
