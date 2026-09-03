import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { firstRow, setDatabaseForTests, type Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { withApiAuth } from "@/lib/http/handler";
import { createTestDatabase } from "@/tests/helpers/database";
import { GET as listStickers } from "@/app/api/v1/stickers/route";

const principal: ApiPrincipal = {
  sub: "request-owner",
  clientId: "ios-client",
  scopes: [],
};

vi.mock("@/lib/auth/bearer", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/lib/auth/bearer")>(),
  requireApiPrincipal: vi.fn(async () => principal),
}));

describe("withApiAuth user provisioning", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    setDatabaseForTests(db);
  });

  afterEach(async () => {
    setDatabaseForTests(undefined);
    await close();
  });

  it("lists stickers without provisioning a new user", async () => {
    const response = await listStickers(new Request("http://localhost/api/v1/stickers"));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ data: [], nextCursor: null });
    expect(await db.select().from(users).where(eq(users.id, principal.sub)).then(firstRow)).toBeUndefined();
    expect(response.headers.get("server-timing")).not.toContain("ensure-user");
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
