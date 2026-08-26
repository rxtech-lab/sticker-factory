import { createClient, type Client } from "@libsql/client";
import { drizzle, type LibSQLDatabase } from "drizzle-orm/libsql";
import * as schema from "@/lib/db/schema";
import { recordSpan } from "@/lib/http/timing";

export type Database = LibSQLDatabase<typeof schema>;

let singleton: { client: Client; db: Database } | undefined;
let testDatabase: Database | undefined;

/**
 * Reports every statement as a `db` span on the in-flight request.
 *
 * Wrapping the driver rather than the query builder means round trips are counted wherever they
 * originate — services, workflow steps, idempotency — so a request log can be compared against the
 * total and the difference attributed to something other than the database.
 */
function instrument(client: Client): Client {
  for (const method of ["execute", "batch", "migrate"] as const) {
    const original = client[method];
    if (typeof original !== "function") continue;
    const bound = original.bind(client) as (...args: unknown[]) => Promise<unknown>;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (client as any)[method] = async (...args: unknown[]) => {
      const startedAt = performance.now();
      try {
        return await bound(...args);
      } finally {
        recordSpan("db", performance.now() - startedAt);
      }
    };
  }
  return client;
}

export function createDatabase(url: string, authToken?: string): { client: Client; db: Database } {
  const client = instrument(createClient({ url, authToken }));
  return { client, db: drizzle(client, { schema }) };
}

export function getDatabase(): Database {
  if (testDatabase) return testDatabase;
  if (singleton) return singleton.db;

  const url = process.env.TURSO_DATABASE_URL
    ?? (process.env.NODE_ENV === "production" ? undefined : "file:local-sticker-factory.db");
  if (!url) throw new Error("TURSO_DATABASE_URL is required at runtime");

  singleton = createDatabase(url, process.env.TURSO_AUTH_TOKEN);
  return singleton.db;
}

export function resetDatabaseForTests(): void {
  singleton?.client.close();
  singleton = undefined;
  testDatabase = undefined;
}

export function setDatabaseForTests(db?: Database): void {
  testDatabase = db;
}
