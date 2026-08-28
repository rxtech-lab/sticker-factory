import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import {
  LibrarySectionsResponseV1Schema,
  PackDetailV1Schema,
  PackListResponseV1Schema,
} from "@/lib/contracts/api";
import { setDatabaseForTests } from "@/lib/db/client";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { GET as listPacks, POST as createPackRoute } from "@/app/api/v1/packs/route";
import { POST as publishRoute } from "@/app/api/v1/packs/[packId]/publish/route";
import { DELETE as uninstallRoute, POST as installRoute } from "@/app/api/v1/packs/[packId]/install/route";
import { GET as sectionsRoute } from "@/app/api/v1/library/sections/route";
import { GET as creatorRoute } from "@/app/api/v1/creators/[handle]/route";

/** Serves a JWKS so the real `withApiAuth` path runs rather than being stubbed out. */
async function startIssuer(): Promise<{ issuer: string; sign: (sub: string, name: string) => Promise<string>; close: () => Promise<void> }> {
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
    // The claim is representative of production OAuth tokens; application user rows stay id-only.
    sign: (sub, name) => new SignJWT({ client_id: "ios-client", name })
      .setProtectedHeader({ alg: "RS256", kid: "test" })
      .setIssuer(issuer)
      .setSubject(sub)
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey),
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

describe("marketplace routes", () => {
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

    await seedUser(db, "pack-creator", "Mika Lin");
    await seedUser(db, "pack-installer", "Sam");
    const member = await seedPublishedSticker(db, "pack-creator", { title: "Loaf" });
    const own = await seedPublishedSticker(db, "pack-installer", { title: "My Own" });

    const tokens = {
      creator: await issuer.sign("pack-creator", "Mika Lin"),
      installer: await issuer.sign("pack-installer", "Sam"),
    };
    const headers = (who: keyof typeof tokens, key?: string) => ({
      authorization: `Bearer ${tokens[who]}`,
      "content-type": "application/json",
      ...(key ? { "idempotency-key": key } : {}),
    });

    return { db, close, issuer, member, own, headers };
  }

  it("carries a pack from creation to a second user's library sections", async () => {
    const { close, issuer, member, own, headers } = await setup();
    try {
      const created = await createPackRoute(new Request("http://localhost/api/v1/packs", {
        method: "POST",
        headers: headers("creator", "pack-key-0001"),
        body: JSON.stringify({ title: "Cozy Cats", summary: "Cats.", stickerIds: [member.stickerId] }),
      }));
      expect(created.status).toBe(201);
      const pack = PackDetailV1Schema.parse(await created.json());
      expect(pack).toMatchObject({ state: "draft", itemCount: 1, isMine: true, installed: false });
      expect(pack.creator.handle).toMatch(/^mika-lin-/);

      const params = { params: Promise.resolve({ packId: pack.id }) };
      const published = await publishRoute(
        new Request(`http://localhost/api/v1/packs/${pack.id}/publish`, { method: "POST", headers: headers("creator", "pub-key-0001") }),
        params,
      );
      expect(PackDetailV1Schema.parse(await published.json()).state).toBe("published");

      // Browse is viewer-relative: the same row says `isMine` to one user and not the other.
      const browsed = await listPacks(new Request("http://localhost/api/v1/packs?sort=popular", { headers: headers("installer") }));
      const list = PackListResponseV1Schema.parse(await browsed.json());
      expect(list.data.map((row) => row.id)).toEqual([pack.id]);
      expect(list.data[0]).toMatchObject({ isMine: false, installed: false, installCount: 0 });

      const installRequest = () => installRoute(
        new Request(`http://localhost/api/v1/packs/${pack.id}/install`, { method: "POST", headers: headers("installer", "inst-key-0001") }),
        params,
      );
      const installed = await installRequest();
      expect(installed.status).toBe(200);
      expect(installed.headers.get("idempotency-replayed")).toBe("false");
      expect(await installed.json()).toEqual({ packId: pack.id, installed: true });

      // A retried install replays rather than double counting.
      const replayed = await installRequest();
      expect(replayed.headers.get("idempotency-replayed")).toBe("true");

      const sections = LibrarySectionsResponseV1Schema.parse(await (await sectionsRoute(
        new Request("http://localhost/api/v1/library/sections?status=published", { headers: headers("installer") }),
      )).json());
      expect(sections.sections.map((section) => section.id)).toEqual(["mine", `pack:${pack.id}`]);
      expect(sections.sections[0].stickers.map((sticker) => sticker.id)).toEqual([own.stickerId]);
      expect(sections.sections[1].stickers.map((sticker) => sticker.title)).toEqual(["Loaf"]);
      expect(sections.sections[1].creator?.displayName).toBe("Mika Lin");

      const creatorPage = await creatorRoute(
        new Request(`http://localhost/api/v1/creators/${pack.creator.handle}`, { headers: headers("installer") }),
        { params: Promise.resolve({ handle: pack.creator.handle }) },
      );
      const byCreator = await creatorPage.json() as { creator: { packCount: number }; data: { id: string; installCount: number }[] };
      expect(byCreator.creator.packCount).toBe(1);
      expect(byCreator.data[0]).toMatchObject({ id: pack.id, installCount: 1 });

      const removed = await uninstallRoute(
        new Request(`http://localhost/api/v1/packs/${pack.id}/install`, { method: "DELETE", headers: headers("installer", "uninst-key-0001") }),
        params,
      );
      expect(await removed.json()).toEqual({ packId: pack.id, installed: false });
      const after = LibrarySectionsResponseV1Schema.parse(await (await sectionsRoute(
        new Request("http://localhost/api/v1/library/sections", { headers: headers("installer") }),
      )).json());
      expect(after.sections.map((section) => section.id)).toEqual(["mine"]);
    } finally {
      await issuer.close();
      await close();
    }
  });

  it("refuses a mutation with no idempotency key and a draft pack to a stranger", async () => {
    const { close, issuer, member, headers } = await setup();
    try {
      const keyless = await createPackRoute(new Request("http://localhost/api/v1/packs", {
        method: "POST",
        headers: headers("creator"),
        body: JSON.stringify({ title: "Keyless", stickerIds: [member.stickerId] }),
      }));
      expect(keyless.status).toBe(400);

      const created = await createPackRoute(new Request("http://localhost/api/v1/packs", {
        method: "POST",
        headers: headers("creator", "pack-key-0002"),
        body: JSON.stringify({ title: "Private Draft", stickerIds: [member.stickerId] }),
      }));
      const pack = PackDetailV1Schema.parse(await created.json());

      // A draft is invisible to browse and cannot be installed by anyone.
      const browsed = await listPacks(new Request("http://localhost/api/v1/packs", { headers: headers("installer") }));
      expect(PackListResponseV1Schema.parse(await browsed.json()).data).toEqual([]);
      const blocked = await installRoute(
        new Request(`http://localhost/api/v1/packs/${pack.id}/install`, { method: "POST", headers: headers("installer", "inst-key-0002") }),
        { params: Promise.resolve({ packId: pack.id }) },
      );
      expect(blocked.status).toBe(404);

      // ...including its own creator, whose stickers are already in their "mine" section.
      const selfInstall = await installRoute(
        new Request(`http://localhost/api/v1/packs/${pack.id}/install`, { method: "POST", headers: headers("creator", "inst-key-0003") }),
        { params: Promise.resolve({ packId: pack.id }) },
      );
      expect(selfInstall.status).toBe(404);
    } finally {
      await issuer.close();
      await close();
    }
  });
});
