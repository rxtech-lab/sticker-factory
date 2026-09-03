import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { firstRow, type Database } from "@/lib/db/client";
import { deviceTokens, users } from "@/lib/db/schema";
import { getApnsConfig, type ApnsConfig, type ApnsPush, type ApnsResult } from "@/lib/notifications/apns";
import {
  generationAlert,
  generationCollapseId,
  generationPayload,
  isNotifiableJobKind,
  notifyGenerationFinished,
} from "@/lib/notifications/generation";
import {
  disableDeviceToken,
  listActiveDeviceTokens,
  registerDeviceToken,
  unregisterDeviceToken,
} from "@/lib/services/devices";
import { createTestDatabase } from "@/tests/helpers/database";

const CONFIG: ApnsConfig = {
  keyId: "KEY123",
  teamId: "TEAM123",
  privateKey: "unused — the sender is injected",
  bundleId: "app.rxlab.sticker-factory",
};

const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

/// Shaped like a `.p8` but not one: `getApnsConfig` only normalizes the text, it never imports it.
const PEM = "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----";

function ok(push: ApnsPush): ApnsResult {
  return { token: push.token, ok: true, status: 200, permanentlyGone: false };
}

function gone(push: ApnsPush): ApnsResult {
  return { token: push.token, ok: false, status: 410, reason: "Unregistered", permanentlyGone: true };
}

async function seedUsers(db: Database) {
  const now = new Date();
  await db.insert(users).values([
    { id: "owner-a", email: "a@example.test", displayName: "Ada", createdAt: now, updatedAt: now },
    { id: "owner-b", email: "b@example.test", displayName: "Bo", createdAt: now, updatedAt: now },
  ]);
}

describe("APNs configuration", () => {
  const KEYS = ["APNS_KEY_ID", "APNS_TEAM_ID", "APNS_PRIVATE_KEY", "APNS_BUNDLE_ID", "APNS_ENVIRONMENT"] as const;
  const saved = new Map<string, string | undefined>();

  beforeEach(() => {
    for (const key of KEYS) {
      saved.set(key, process.env[key]);
      delete process.env[key];
    }
  });

  afterEach(() => {
    for (const key of KEYS) {
      const value = saved.get(key);
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
  });

  function configure(overrides: Record<string, string> = {}) {
    process.env.APNS_KEY_ID = "KEY123";
    process.env.APNS_TEAM_ID = "TEAM123";
    process.env.APNS_PRIVATE_KEY = PEM;
    process.env.APNS_BUNDLE_ID = "app.rxlab.stickerfactory";
    Object.assign(process.env, overrides);
  }

  /// Not an error state: local development, tests, and any environment not yet given a `.p8`.
  it("is absent until all four credentials are present", () => {
    expect(getApnsConfig()).toBeUndefined();
    configure();
    delete process.env.APNS_BUNDLE_ID;
    expect(getApnsConfig()).toBeUndefined();
    configure();
    expect(getApnsConfig()?.bundleId).toBe("app.rxlab.stickerfactory");
  });

  /// The three shapes an environment variable manages to carry a `.p8` in.
  it("accepts the key as a PEM, an escaped PEM, or base64", () => {
    configure();
    expect(getApnsConfig()?.privateKey).toBe(`${PEM}\n`);

    configure({ APNS_PRIVATE_KEY: PEM.replace(/\n/g, "\\n") });
    expect(getApnsConfig()?.privateKey).toBe(`${PEM}\n`);

    configure({ APNS_PRIVATE_KEY: Buffer.from(PEM, "utf8").toString("base64") });
    expect(getApnsConfig()?.privateKey).toBe(`${PEM}\n`);
  });

  /// Apple calls the same host "sandbox" in the docs and "development" in the entitlement, and the
  /// sibling relay service accepts both — copying its configuration across must not silently
  /// degrade to per-device routing.
  it("takes either of Apple's names for each host, and nothing else", () => {
    configure({ APNS_ENVIRONMENT: "development" });
    expect(getApnsConfig()?.environment).toBe("sandbox");

    configure({ APNS_ENVIRONMENT: "Production" });
    expect(getApnsConfig()?.environment).toBe("production");

    // Empty means "let each device's registration decide", which is the default deployment.
    configure({ APNS_ENVIRONMENT: "" });
    expect(getApnsConfig()?.environment).toBeUndefined();
  });
});

describe("device token registration", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await seedUsers(db);
  });

  afterEach(async () => {
    await close();
  });

  it("registers a device and lists it as reachable", async () => {
    await registerDeviceToken(db, "owner-a", {
      token: TOKEN_A,
      platform: "ios",
      environment: "sandbox",
      bundleId: "app.rxlab.sticker-factory",
      appVersion: "1.2.0",
    });

    const devices = await listActiveDeviceTokens(db, "owner-a");
    expect(devices).toHaveLength(1);
    expect(devices[0].environment).toBe("sandbox");
    expect(devices[0].appVersion).toBe("1.2.0");
  });

  it("re-registering the same token is one row, not two", async () => {
    const input = { token: TOKEN_A, platform: "ios", environment: "production" } as const;
    await registerDeviceToken(db, "owner-a", input);
    await registerDeviceToken(db, "owner-a", input);

    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(1);
  });

  /// One phone, two accounts: the token names the install, so the second sign-in takes it over.
  it("moves a token to whichever account registered it last", async () => {
    const input = { token: TOKEN_A, platform: "ios", environment: "production" } as const;
    await registerDeviceToken(db, "owner-a", input);
    await registerDeviceToken(db, "owner-b", input);

    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(0);
    expect(await listActiveDeviceTokens(db, "owner-b")).toHaveLength(1);
  });

  it("a disabled token stops being reachable, and registering again revives it", async () => {
    const input = { token: TOKEN_A, platform: "ios", environment: "production" } as const;
    await registerDeviceToken(db, "owner-a", input);
    await disableDeviceToken(db, TOKEN_A, "Unregistered");
    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(0);

    await registerDeviceToken(db, "owner-a", input);
    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(1);
  });

  it("only the owning account can unregister a device", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });

    await unregisterDeviceToken(db, "owner-b", TOKEN_A);
    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(1);

    await unregisterDeviceToken(db, "owner-a", TOKEN_A);
    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(0);
  });
});

describe("generation push", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await seedUsers(db);
  });

  afterEach(async () => {
    await close();
  });

  const notification = {
    ownerId: "owner-a",
    jobId: "job-1",
    stickerId: "sticker-1",
    stickerTitle: "Dancing cat",
    outcome: "ready" as const,
  };

  it("says what happened, in the sticker's own name", () => {
    expect(generationAlert("ready", "Dancing cat")).toEqual({
      title: "Sticker ready",
      body: "Dancing cat finished generating. Tap to take a look.",
    });
    expect(generationAlert("failed", "Dancing cat").body).toContain("retry");
    // An untitled sticker still gets a sentence rather than a leading space.
    expect(generationAlert("ready", "   ").body).toMatch(/^Your sticker/);
  });

  it("carries the sticker id the app opens on a tap", () => {
    const payload = generationPayload(notification);
    expect(payload.stickerID).toBe("sticker-1");
    expect((payload.aps as { alert: { title: string } }).alert.title).toBe("Sticker ready");
  });

  /// The collapse id is what stops a re-run of the step from stacking a second banner for one turn.
  it("collapses per job and outcome", () => {
    expect(generationCollapseId(notification)).toBe("gen-job-1-ready");
    expect(generationCollapseId({ ...notification, outcome: "failed" })).not.toBe(generationCollapseId(notification));
  });

  it("is silent about housekeeping", () => {
    expect(isNotifiableJobKind("image")).toBe(true);
    expect(isNotifiableJobKind("chat")).toBe(true);
    expect(isNotifiableJobKind("cleanup")).toBe(false);
    expect(isNotifiableJobKind("export")).toBe(false);
  });

  it("pushes to every device the owner is signed in on", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });
    await registerDeviceToken(db, "owner-a", { token: TOKEN_B, platform: "ios", environment: "sandbox" });
    await registerDeviceToken(db, "owner-b", { token: "c".repeat(64), platform: "ios", environment: "production" });

    const sent: ApnsPush[] = [];
    await notifyGenerationFinished(db, notification, {
      config: CONFIG,
      send: async (pushes) => { sent.push(...pushes); return pushes.map(ok); },
    });

    expect(sent.map((push) => push.token).sort()).toEqual([TOKEN_A, TOKEN_B]);
    expect(sent.every((push) => push.collapseId === "gen-job-1-ready")).toBe(true);
  });

  it("stops trying a token Apple says is gone", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });
    await registerDeviceToken(db, "owner-a", { token: TOKEN_B, platform: "ios", environment: "production" });

    await notifyGenerationFinished(db, notification, {
      config: CONFIG,
      send: async (pushes) => pushes.map((push) => (push.token === TOKEN_A ? gone(push) : ok(push))),
    });

    const remaining = await listActiveDeviceTokens(db, "owner-a");
    expect(remaining.map((device) => device.token)).toEqual([TOKEN_B]);
    const disabled = await db.select().from(deviceTokens).where(eq(deviceTokens.token, TOKEN_A)).then(firstRow);
    expect(disabled?.disabledReason).toBe("Unregistered");
  });

  /// A transient failure says nothing about the token — losing it would silence the device forever.
  it("keeps a token that only failed to send", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });

    await notifyGenerationFinished(db, notification, {
      config: CONFIG,
      send: async (pushes) => pushes.map((push) => ({
        token: push.token,
        ok: false,
        status: 429,
        reason: "TooManyRequests",
        permanentlyGone: false,
      })),
    });

    expect(await listActiveDeviceTokens(db, "owner-a")).toHaveLength(1);
  });

  /// The banner is a courtesy. A sticker that generated must never be reported as failed because
  /// Apple was unreachable, so nothing in here is allowed to throw.
  it("swallows a sender that blows up", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });

    await expect(notifyGenerationFinished(db, notification, {
      config: CONFIG,
      send: async () => { throw new Error("APNs is on fire"); },
    })).resolves.toBeUndefined();
  });

  it("does nothing when the deployment has no APNs credentials", async () => {
    await registerDeviceToken(db, "owner-a", { token: TOKEN_A, platform: "ios", environment: "production" });

    let called = false;
    await notifyGenerationFinished(db, notification, {
      config: undefined,
      send: async (pushes) => { called = true; return pushes.map(ok); },
    });

    expect(called).toBe(false);
  });
});
