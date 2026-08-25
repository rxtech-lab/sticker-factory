import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { setDatabaseForTests } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { appendGenerationEvent } from "@/lib/services/events";
import { createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { GET } from "@/app/api/v1/jobs/[jobId]/events/route";

/**
 * Serves a JWKS so the real `withApiAuth` path runs, rather than being stubbed out. The bug this
 * suite guards against was in transport behaviour, so the transport is what has to be exercised.
 */
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

/** Reads SSE frames off the response body as they arrive, stopping after `count` events. */
async function readFrames(body: ReadableStream<Uint8Array>, count: number, timeoutMs = 10_000) {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  const frames: Array<{ id?: number; event?: string; data?: unknown; at: number }> = [];
  const started = Date.now();
  let buffer = "";
  try {
    while (frames.length < count && Date.now() - started < timeoutMs) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let split = buffer.indexOf("\n\n");
      while (split >= 0) {
        const raw = buffer.slice(0, split);
        buffer = buffer.slice(split + 2);
        const lines = raw.split("\n");
        const dataLine = lines.find((line) => line.startsWith("data:"));
        if (dataLine) {
          const idLine = lines.find((line) => line.startsWith("id:"));
          frames.push({
            id: idLine ? Number(idLine.slice(3).trim()) : undefined,
            event: lines.find((line) => line.startsWith("event:"))?.slice(6).trim(),
            data: JSON.parse(dataLine.slice(5).trim()),
            at: Date.now() - started,
          });
        }
        split = buffer.indexOf("\n\n");
      }
    }
  } finally {
    await reader.cancel();
  }
  return frames;
}

describe("generation event stream", () => {
  afterEach(() => {
    setDatabaseForTests(undefined);
    setObjectStoreForTests(undefined);
    setAiProviderForTests(undefined);
  });

  it("delivers frames as they are produced, not buffered until the response ends", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const issuer = await startIssuer();
    process.env.AUTH_ISSUER = issuer.issuer;
    process.env.RXLAB_ALLOWED_CLIENT_IDS = "ios-client";
    await db.insert(users).values({ id: "stream-owner", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "stream-owner", {
      title: "Stream", kind: "static", prompt: "Cloud", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "stream-owner", sticker.stickerId, {
      text: "Cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });

    const token = await issuer.sign("stream-owner");
    const response = await GET(
      new Request(`http://localhost/api/v1/jobs/${turn.jobId}/events`, {
        headers: { authorization: `Bearer ${token}`, accept: "text/event-stream" },
      }),
      { params: Promise.resolve({ jobId: turn.jobId }) },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("text/event-stream");
    // Any compression or proxy buffering layer here would turn the live stream into one blob.
    expect(response.headers.get("content-encoding")).toBe("identity");
    expect(response.headers.get("x-accel-buffering")).toBe("no");
    expect(response.headers.get("cache-control")).toContain("no-transform");

    // Append a second event only after the stream is already open, so receiving it proves the
    // response body is being flushed incrementally rather than assembled at the end.
    const late = (async () => {
      await new Promise((resolve) => setTimeout(resolve, 400));
      await appendGenerationEvent(db, turn.jobId, "stream-owner", "progress", { stage: "late", progress: 0.5 });
    })();

    const frames = await readFrames(response.body!, 2);
    await late;

    expect(frames.length).toBeGreaterThanOrEqual(2);
    expect(frames[0].event).toBe("queued");
    expect(frames.at(-1)?.event).toBe("progress");
    expect((frames.at(-1)?.data as { data: { stage?: string } }).data.stage).toBe("late");
    // The first frame must not have waited on the late one.
    expect(frames[0].at).toBeLessThan(frames.at(-1)!.at);

    await issuer.close();
    await close();
  });

  it("replays from Last-Event-ID and ends with a terminal frame", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    const issuer = await startIssuer();
    process.env.AUTH_ISSUER = issuer.issuer;
    process.env.RXLAB_ALLOWED_CLIENT_IDS = "ios-client";
    await db.insert(users).values({ id: "replay-owner", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "replay-owner", {
      title: "Replay", kind: "static", prompt: "Cloud", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "replay-owner", sticker.stickerId, {
      text: "Cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    const { stickerGenerationWorkflow } = await import("@/workflows/sticker-generation");
    await stickerGenerationWorkflow(turn.jobId);

    const token = await issuer.sign("replay-owner");
    const request = (cursor?: string) => new Request(`http://localhost/api/v1/jobs/${turn.jobId}/events`, {
      headers: {
        authorization: `Bearer ${token}`,
        accept: "text/event-stream",
        ...(cursor ? { "last-event-id": cursor } : {}),
      },
    });

    const all = await readFrames(
      (await GET(request(), { params: Promise.resolve({ jobId: turn.jobId }) })).body!,
      50,
      3_000,
    );
    expect(all.at(-1)?.event).toBe("end");
    const events = all.filter((frame) => frame.event !== "end");
    expect(events.at(-1)?.event).toBe("completed");
    // The assistant turn rides on the terminal event so the client need not refetch to render it.
    expect((events.at(-1)?.data as { data: { assistantMessage?: { content?: string } } }).data.assistantMessage?.content)
      .toBeTruthy();

    const resumed = await readFrames(
      (await GET(request(String(events[0].id)), { params: Promise.resolve({ jobId: turn.jobId }) })).body!,
      50,
      3_000,
    );
    expect(resumed.filter((frame) => frame.event !== "end").map((frame) => frame.id))
      .toEqual(events.slice(1).map((frame) => frame.id));

    await issuer.close();
    await close();
  });
});
