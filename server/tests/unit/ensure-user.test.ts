import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import type { Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { ensureUser } from "@/lib/services/users";
import { createTestDatabase } from "@/tests/helpers/database";

function principal(overrides: Partial<ApiPrincipal> = {}): ApiPrincipal {
  return {
    sub: "owner-a",
    clientId: "client-a",
    email: "a@example.test",
    name: "Ada",
    scopes: [],
    ...overrides,
  };
}

describe("ensureUser", () => {
  let db: Database;
  let close: () => Promise<void>;
  let writes: number;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    writes = 0;
    const insert = db.insert.bind(db);
    db.insert = ((table: Parameters<typeof insert>[0]) => {
      writes += 1;
      return insert(table);
    }) as typeof db.insert;
  });

  afterEach(async () => {
    await close();
  });

  it("creates the row on first sight", async () => {
    await ensureUser(db, principal());
    const row = await db.select().from(users).where(eq(users.id, "owner-a")).get();
    expect(row?.email).toBe("a@example.test");
    expect(row?.displayName).toBe("Ada");
    expect(writes).toBe(1);
  });

  it("does not write again for a principal it has already ensured", async () => {
    await ensureUser(db, principal());
    await ensureUser(db, principal());
    await ensureUser(db, principal());
    expect(writes).toBe(1);
  });

  it("writes when the token's profile drifts from the stored row", async () => {
    await ensureUser(db, principal());
    await ensureUser(db, principal({ name: "Ada Lovelace" }));
    expect(writes).toBe(2);
    const row = await db.select().from(users).where(eq(users.id, "owner-a")).get();
    expect(row?.displayName).toBe("Ada Lovelace");
  });

  it("adopts a row written by another instance without rewriting it", async () => {
    const now = new Date();
    await db.insert(users).values({
      id: "owner-b",
      email: "b@example.test",
      displayName: "Grace",
      createdAt: now,
      updatedAt: now,
    });
    writes = 0;

    await ensureUser(db, principal({ sub: "owner-b", email: "b@example.test", name: "Grace" }));
    expect(writes).toBe(0);
  });

  it("keeps its bookkeeping per database", async () => {
    await ensureUser(db, principal());
    const other = await createTestDatabase();
    try {
      await ensureUser(other.db, principal());
      const row = await other.db.select().from(users).where(eq(users.id, "owner-a")).get();
      expect(row?.email).toBe("a@example.test");
    } finally {
      await other.close();
    }
  });

  it("treats a missing email or name as null rather than churning", async () => {
    const anonymous = principal({ email: undefined, name: undefined });
    await ensureUser(db, anonymous);
    const row = await db.select().from(users).where(eq(users.id, "owner-a")).get();
    expect(row?.email).toBeNull();
    expect(row?.displayName).toBeNull();
    expect(writes).toBe(1);

    await ensureUser(db, anonymous);
    expect(writes).toBe(1);
  });
});
