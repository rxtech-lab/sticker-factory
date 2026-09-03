import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { firstRow, type Database } from "@/lib/db/client";
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
    const row = await db.select().from(users).where(eq(users.id, "owner-a")).then(firstRow);
    expect(row).toMatchObject({ id: "owner-a", email: null, displayName: null });
    expect(writes).toBe(1);
  });

  it("does not write again for a principal it has already ensured", async () => {
    await ensureUser(db, principal());
    await ensureUser(db, principal());
    await ensureUser(db, principal());
    expect(writes).toBe(1);
  });

  it("ignores OAuth profile drift because this database stores only the subject id", async () => {
    await ensureUser(db, principal());
    await ensureUser(db, principal({ name: "Ada Lovelace" }));
    expect(writes).toBe(1);
    const row = await db.select().from(users).where(eq(users.id, "owner-a")).then(firstRow);
    expect(row).toMatchObject({ email: null, displayName: null });
  });

  it("does not overwrite an existing row", async () => {
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
    expect(writes).toBe(1);
    const row = await db.select().from(users).where(eq(users.id, "owner-b")).then(firstRow);
    expect(row).toMatchObject({ email: "b@example.test", displayName: "Grace" });
  });

  it("coalesces concurrent first requests into one insert", async () => {
    await Promise.all([
      ensureUser(db, principal()),
      ensureUser(db, principal()),
      ensureUser(db, principal()),
    ]);
    expect(writes).toBe(1);
  });

  it("keeps its bookkeeping per database", async () => {
    await ensureUser(db, principal());
    const other = await createTestDatabase();
    try {
      await ensureUser(other.db, principal());
      const row = await other.db.select().from(users).where(eq(users.id, "owner-a")).then(firstRow);
      expect(row).toMatchObject({ id: "owner-a", email: null, displayName: null });
    } finally {
      await other.close();
    }
  });
});
