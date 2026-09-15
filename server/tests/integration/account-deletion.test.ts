import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { eq } from "drizzle-orm";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { afterEach, describe, expect, it } from "vitest";
import { DELETE, GET, POST } from "@/app/api/v1/account/deletion/route";
import { GET as CRON } from "@/app/api/cron/account-deletion/route";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";

/**
 * The account-deletion route across its real seam: the bearer verification in `withApiAuth`, and the
 * forwarding to the identity provider. Both ends are stood up for real — a JWKS the token actually
 * verifies against, and an `/api/oauth/account-deletion` endpoint that answers like rxlab-auth — so
 * the ordering between the two systems is exercised rather than described.
 */

type IdpBehaviour = {
  /** Status for the next write. 200 unless a test wants a refusal. */
  status?: number;
  body?: unknown;
};

interface FakeIdp {
  issuer: string;
  sign: (sub: string) => Promise<string>;
  /** Every method the app forwarded, in order. */
  calls: string[];
  pending: { scheduledAt: number } | null;
  next: IdpBehaviour | null;
  close: () => Promise<void>;
}

async function startIdp(): Promise<FakeIdp> {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), alg: "RS256", use: "sig", kid: "test" };

  const state: Pick<FakeIdp, "calls" | "pending" | "next"> = { calls: [], pending: null, next: null };

  const server: Server = createServer((request, response) => {
    if (request.url === "/.well-known/jwks.json") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ keys: [jwk] }));
      return;
    }
    if (request.url === "/api/oauth/account-deletion") {
      const method = request.method ?? "GET";
      state.calls.push(method);

      const override = state.next;
      if (override && method !== "GET") {
        state.next = null;
        response.writeHead(override.status ?? 200, { "content-type": "application/json" });
        response.end(JSON.stringify(override.body ?? {}));
        return;
      }

      if (method === "POST" && !state.pending) {
        state.pending = { scheduledAt: Math.floor(Date.now() / 1000) + 7 * 24 * 60 * 60 };
      }
      if (method === "DELETE") state.pending = null;

      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        deletion_pending: state.pending !== null,
        deletion_scheduled_at: state.pending?.scheduledAt ?? null,
        deletion_requested_at: state.pending ? Math.floor(Date.now() / 1000) : null,
      }));
      return;
    }
    response.writeHead(404).end();
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const issuer = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  return {
    issuer,
    get calls() { return state.calls; },
    get pending() { return state.pending; },
    set pending(value) { state.pending = value; },
    set next(value) { state.next = value; },
    get next() { return state.next; },
    sign: (sub) => new SignJWT({ client_id: "ios-client", scope: "openid write:profile" })
      .setProtectedHeader({ alg: "RS256", kid: "test" })
      .setIssuer(issuer)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey),
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  } as FakeIdp;
}

describe("/v1/account/deletion", () => {
  afterEach(() => {
    setDatabaseForTests(undefined);
    setObjectStoreForTests(undefined);
    delete process.env.CRON_SECRET;
  });

  async function setup() {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    const idp = await startIdp();
    process.env.AUTH_ISSUER = idp.issuer;
    process.env.RXLAB_ALLOWED_CLIENT_IDS = "ios-client";
    await db.insert(users).values({ id: "owner", createdAt: new Date(), updatedAt: new Date() });

    const token = await idp.sign("owner");
    const call = (handler: (request: Request) => Promise<Response>, method: string) => handler(
      new Request("http://localhost/api/v1/account/deletion", {
        method,
        headers: { authorization: `Bearer ${token}` },
      }),
    );

    return {
      db,
      idp,
      status: () => call(GET, "GET"),
      schedule: () => call(POST, "POST"),
      cancel: () => call(DELETE, "DELETE"),
      close: async () => {
        await idp.close();
        await close();
      },
    };
  }

  it("reports nothing pending, then schedules on both sides at the same instant", async () => {
    const { idp, status, schedule, db, close } = await setup();
    try {
      expect(await (await status()).json()).toMatchObject({ pendingDeletion: false, deletionScheduledAt: null });

      const response = await schedule();
      expect(response.status).toBe(200);
      const body = await response.json() as { pendingDeletion: boolean; deletionScheduledAt: string };
      expect(body.pendingDeletion).toBe(true);

      // The identity provider decides the deadline; we adopt it rather than computing a second one.
      expect(idp.calls).toEqual(["POST"]);
      expect(new Date(body.deletionScheduledAt).getTime() / 1000).toBe(idp.pending?.scheduledAt);

      const row = await db.select().from(users).where(eq(users.id, "owner")).then(firstRow);
      expect(row?.deletionScheduledAt?.toISOString()).toBe(body.deletionScheduledAt);
      expect(await (await status()).json()).toMatchObject({ pendingDeletion: true });
    } finally {
      await close();
    }
  });

  it("keeps the original deadline when the request is repeated", async () => {
    const { schedule, close } = await setup();
    try {
      const first = await (await schedule()).json() as { deletionScheduledAt: string };
      const second = await (await schedule()).json() as { deletionScheduledAt: string };
      expect(second.deletionScheduledAt).toBe(first.deletionScheduledAt);
    } finally {
      await close();
    }
  });

  it("cancels here first, then at the identity provider", async () => {
    const { idp, schedule, cancel, status, close } = await setup();
    try {
      await schedule();
      idp.calls.length = 0;

      expect(await (await cancel()).json()).toMatchObject({ pendingDeletion: false, deletionScheduledAt: null });
      expect(idp.calls).toEqual(["DELETE"]);
      expect(idp.pending).toBeNull();
      expect(await (await status()).json()).toMatchObject({ pendingDeletion: false });
    } finally {
      await close();
    }
  });

  /**
   * The failure that must not happen: the identity provider cancels, our write fails, and this
   * server goes on to purge the stickers of a live account. Cancelling locally first means a failed
   * forward leaves the account scheduled but its work intact.
   */
  it("does not leave the account deletable here when the identity provider refuses the cancel", async () => {
    const { idp, schedule, cancel, db, close } = await setup();
    try {
      await schedule();
      idp.next = { status: 500, body: { error: "server_error" } };

      await expect(cancel()).resolves.toMatchObject({ status: 502 });

      const row = await db.select().from(users).where(eq(users.id, "owner")).then(firstRow);
      expect(row?.deletionScheduledAt).toBeNull();
      expect(row?.deletedAt).toBeNull();
    } finally {
      await close();
    }
  });

  it("does not schedule locally when the token lacks the scope to delete the account", async () => {
    const { idp, schedule, db, close } = await setup();
    try {
      idp.next = {
        status: 403,
        body: { error: "insufficient_scope", error_description: "Managing account deletion requires the write:profile scope" },
      };

      const response = await schedule();
      expect(response.status).toBe(403);
      const body = await response.json() as { error: { code: string } };
      expect(body.error.code).toBe("ACCOUNT_DELETION_SCOPE_REQUIRED");

      // Nothing was written here, so no sweep can act on a deletion the account service refused.
      const row = await db.select().from(users).where(eq(users.id, "owner")).then(firstRow);
      expect(row?.deletionScheduledAt).toBeNull();
    } finally {
      await close();
    }
  });

  it("rejects an unauthenticated request", async () => {
    const { close } = await setup();
    try {
      const response = await GET(new Request("http://localhost/api/v1/account/deletion"));
      expect(response.status).toBe(401);
    } finally {
      await close();
    }
  });

  describe("the cron sweep", () => {
    const cron = (secret?: string) => CRON(new Request("http://localhost/api/cron/account-deletion", {
      headers: secret === undefined ? {} : { authorization: `Bearer ${secret}` },
    }));

    it("refuses to run at all when no secret is configured", async () => {
      const { close } = await setup();
      try {
        delete process.env.CRON_SECRET;
        expect((await cron("anything")).status).toBe(503);
      } finally {
        await close();
      }
    });

    it("rejects a wrong or missing secret", async () => {
      const { close } = await setup();
      try {
        process.env.CRON_SECRET = "correct-horse";
        expect((await cron()).status).toBe(401);
        expect((await cron("")).status).toBe(401);
        expect((await cron("correct-hors")).status).toBe(401);
        expect((await cron("correct-horsey")).status).toBe(401);
      } finally {
        await close();
      }
    });

    it("finalizes a deletion once its grace window has passed", async () => {
      const { schedule, db, close } = await setup();
      try {
        process.env.CRON_SECRET = "correct-horse";
        await schedule();

        // Nothing is due yet.
        expect(await (await cron("correct-horse")).json()).toEqual({ deleted: 0, skipped: 0 });

        // Bring the deadline back past the sweep's grace window.
        await db.update(users)
          .set({ deletionScheduledAt: new Date(Date.now() - 60 * 60 * 1000) })
          .where(eq(users.id, "owner"));

        expect(await (await cron("correct-horse")).json()).toEqual({ deleted: 1, skipped: 0 });

        const row = await db.select().from(users).where(eq(users.id, "owner")).then(firstRow);
        expect(row?.displayName).toBe("deleted-account");
        expect(row?.deletedAt).not.toBeNull();
      } finally {
        await close();
      }
    });
  });
});
