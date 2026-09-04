import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { firstRow, setDatabaseForTests, type Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { withApiAuth } from "@/lib/http/handler";
import { createTestDatabase } from "@/tests/helpers/database";
import { GET as listStickers } from "@/app/api/v1/stickers/route";
import { GET as listLibrarySections } from "@/app/api/v1/library/sections/route";

const principal: ApiPrincipal = {
  sub: "request-owner",
  clientId: "ios-client",
  scopes: [],
};

const savedMinimum = process.env.IOS_MINIMUM_APP_VERSION;
const savedIOSClientId = process.env.IOS_OAUTH_CLIENT_ID;

vi.mock("@/lib/auth/bearer", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/lib/auth/bearer")>(),
  requireApiPrincipal: vi.fn(async () => principal),
}));

describe("withApiAuth user provisioning", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    delete process.env.IOS_MINIMUM_APP_VERSION;
    ({ db, close } = await createTestDatabase());
    setDatabaseForTests(db);
  });

  afterEach(async () => {
    setDatabaseForTests(undefined);
    await close();
    restoreEnvironment("IOS_MINIMUM_APP_VERSION", savedMinimum);
    restoreEnvironment("IOS_OAUTH_CLIENT_ID", savedIOSClientId);
  });

  it("lists stickers without provisioning a new user", async () => {
    const response = await listStickers(new Request("http://localhost/api/v1/stickers"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ data: [], nextCursor: null });
    expect(await db.select().from(users).where(eq(users.id, principal.sub)).then(firstRow)).toBeUndefined();
    expect(response.headers.get("server-timing")).not.toContain("ensure-user");
  });

  it("applies the configured iOS minimum to both sticker listing routes", async () => {
    process.env.IOS_OAUTH_CLIENT_ID = principal.clientId;
    process.env.IOS_MINIMUM_APP_VERSION = "1.2";
    const headers = { "x-ios-app-version": "1.1", "accept-language": "en-US" };

    const stickersResponse = await listStickers(new Request("http://localhost/api/v1/stickers", { headers }));
    const sectionsResponse = await listLibrarySections(new Request("http://localhost/api/v1/library/sections", { headers }));

    for (const response of [stickersResponse, sectionsResponse]) {
      expect(response.status).toBe(426);
      expect(await response.json()).toMatchObject({
        error: {
          code: "IOS_APP_UPDATE_REQUIRED",
          message: "Update Winky Sticker House to version 1.2 or later to view your stickers.",
          details: { currentVersion: "1.1", minimumVersion: "1.2" },
        },
      });
    }
  });

  it("does not provision a user for HEAD requests", async () => {
    const response = await withApiAuth(
      new Request("http://localhost/api/v1/stickers", { method: "HEAD" }),
      async () => new Response(null, { status: 204 }),
    );

    expect(response.status).toBe(204);
    expect(await db.select().from(users).where(eq(users.id, principal.sub)).then(firstRow)).toBeUndefined();
    expect(response.headers.get("server-timing")).not.toContain("ensure-user");
  });

  it("provisions the user before a mutation handler runs", async () => {
    let userSeenByHandler: typeof users.$inferSelect | undefined;
    const response = await withApiAuth(
      new Request("http://localhost/api/v1/stickers", { method: "POST" }),
      async (_principal, requestDb) => {
        userSeenByHandler = await requestDb.select().from(users).where(eq(users.id, principal.sub)).then(firstRow);
        return new Response(null, { status: 204 });
      },
    );

    expect(response.status).toBe(204);
    expect(userSeenByHandler).toMatchObject({ id: principal.sub });
    expect(response.headers.get("server-timing")).toContain("ensure-user");
  });
});

function restoreEnvironment(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
