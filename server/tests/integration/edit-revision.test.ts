import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { setDatabaseForTests } from "@/lib/db/client";
import { generationJobs, stickerRevisions, users } from "@/lib/db/schema";
import { acceptRevision, createCandidateRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { POST } from "@/app/api/v1/stickers/[id]/revisions/route";

/** Serves a JWKS so the real `withApiAuth` path runs rather than being stubbed out. */
async function startIssuer(): Promise<{ issuer: string; sign: (sub: string) => Promise<string>; close: () => Promise<void> }> {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const jwk = { ...(await exportJWK(publicKey)), alg: "RS256", use: "sig", kid: "test" };
  const server: Server = createServer((request, response) => {
    if (request.url === "/.well-known/jwks.json") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ keys: [jwk] }));
      return;
    }
    response.writeHead(404).end();
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const issuer = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    issuer,
    sign: (sub) => new SignJWT({ client_id: "ios-client" })
      .setProtectedHeader({ alg: "RS256", kid: "test" })
      .setIssuer(issuer)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey),
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

const document = StickerDocumentSchema.parse({
  version: 2,
  canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
  kind: "static",
  durationSeconds: 0,
  fps: 0,
  loop: "once",
  mp4Background: { type: "solid", color: "#FFFFFF" },
  layers: [{ id: "dot", name: "Dot", type: "shape", shape: { kind: "circle" }, fill: { type: "solid", color: "#FF0000" } }],
});

describe("POST /v1/stickers/:id/revisions", () => {
  afterEach(() => {
    setDatabaseForTests(undefined);
    setObjectStoreForTests(undefined);
  });

  async function setup() {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const issuer = await startIssuer();
    process.env.AUTH_ISSUER = issuer.issuer;
    process.env.RXLAB_ALLOWED_CLIENT_IDS = "ios-client";
    await db.insert(users).values({ id: "edit-owner", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "edit-owner", {
      title: "Cloud", kind: "static", prompt: "Cloud", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "edit-owner", sticker.stickerId, {
      text: "Cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    await db.update(generationJobs).set({ state: "succeeded", completedAt: new Date() })
      .where(eq(generationJobs.id, turn.jobId));
    const parentId = await createCandidateRevision(db, {
      ownerId: "edit-owner",
      stickerId: sticker.stickerId,
      sourceMessageId: turn.messageId,
      document,
    });
    await acceptRevision(db, "edit-owner", sticker.stickerId, parentId);

    const token = await issuer.sign("edit-owner");
    const post = (body: unknown, key: string) => POST(
      new Request(`http://localhost/api/v1/stickers/${sticker.stickerId}/revisions`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
          "idempotency-key": key,
        },
        body: JSON.stringify(body),
      }),
      { params: Promise.resolve({ id: sticker.stickerId }) },
    );

    return { db, close, issuer, stickerId: sticker.stickerId, parentId, post };
  }

  it("creates an accepted revision and returns a compact body", async () => {
    const { close, issuer, parentId, post, db, stickerId } = await setup();
    try {
      const response = await post({ parentRevisionId: parentId, document }, "edit-key-000001");
      expect(response.status).toBe(201);
      const body = await response.json() as Record<string, unknown>;
      expect(body).toMatchObject({ candidateState: "accepted", parentRevisionId: parentId, stickerStatus: "draft" });
      // The response is stored verbatim in the idempotency row, so it must not echo the document.
      expect(body).not.toHaveProperty("document");

      const rows = await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, stickerId));
      expect(rows).toHaveLength(2);
    } finally {
      await issuer.close();
      await close();
    }
  });

  /** A retry after a dropped response must replay, not fork the revision chain. */
  it("replays a repeated idempotency key", async () => {
    const { close, issuer, parentId, post, db, stickerId } = await setup();
    try {
      const first = await post({ parentRevisionId: parentId, document }, "edit-key-000002");
      const second = await post({ parentRevisionId: parentId, document }, "edit-key-000002");
      expect(second.headers.get("idempotency-replayed")).toBe("true");
      expect(await second.json()).toEqual(await first.json());
      const rows = await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, stickerId));
      expect(rows).toHaveLength(2);
    } finally {
      await issuer.close();
      await close();
    }
  });

  /**
   * The request hash covers the whole body, so re-saving a *changed* document under the same key is
   * a conflict. The client has to mint a fresh key per save, not per editing session.
   */
  it("rejects a changed document under a reused key", async () => {
    const { close, issuer, parentId, post } = await setup();
    try {
      await post({ parentRevisionId: parentId, document }, "edit-key-000003");
      const changed = structuredClone(document);
      changed.layers[0].name = "Renamed";
      const response = await post({ parentRevisionId: parentId, document: changed }, "edit-key-000003");
      expect(response.status).toBe(409);
      expect((await response.json() as { error: { code: string } }).error.code).toBe("IDEMPOTENCY_KEY_REUSED");
    } finally {
      await issuer.close();
      await close();
    }
  });

  it("requires an idempotency key", async () => {
    const { close, issuer, parentId, stickerId } = await setup();
    try {
      const token = await issuer.sign("edit-owner");
      const response = await POST(
        new Request(`http://localhost/api/v1/stickers/${stickerId}/revisions`, {
          method: "POST",
          headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
          body: JSON.stringify({ parentRevisionId: parentId, document }),
        }),
        { params: Promise.resolve({ id: stickerId }) },
      );
      expect(response.status).toBe(400);
    } finally {
      await issuer.close();
      await close();
    }
  });

  it("refuses an unauthenticated save", async () => {
    const { close, issuer, parentId, stickerId } = await setup();
    try {
      const response = await POST(
        new Request(`http://localhost/api/v1/stickers/${stickerId}/revisions`, {
          method: "POST",
          headers: { "content-type": "application/json", "idempotency-key": "edit-key-000004" },
          body: JSON.stringify({ parentRevisionId: parentId, document }),
        }),
        { params: Promise.resolve({ id: stickerId }) },
      );
      expect(response.status).toBe(401);
    } finally {
      await issuer.close();
      await close();
    }
  });

  it("rejects a malformed document with a validation error rather than a 500", async () => {
    const { close, issuer, parentId, post } = await setup();
    try {
      const response = await post({
        parentRevisionId: parentId,
        // A shape with neither fill nor stroke draws nothing, and the contract says so.
        document: { ...structuredClone(document), layers: [{ id: "dot", name: "Dot", type: "shape", shape: { kind: "circle" } }] },
      }, "edit-key-000005");
      expect(response.status).toBe(400);
      expect((await response.json() as { error: { code: string } }).error.code).toBe("VALIDATION_ERROR");
    } finally {
      await issuer.close();
      await close();
    }
  });
});
