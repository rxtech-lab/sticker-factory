import { createClient, type Client } from "@libsql/client";
import { drizzle, type LibSQLDatabase } from "drizzle-orm/libsql";
import * as schema from "@/lib/db/schema";

export type Database = LibSQLDatabase<typeof schema>;

let singleton: { client: Client; db: Database } | undefined;
let testDatabase: Database | undefined;

export function createDatabase(url: string, authToken?: string): { client: Client; db: Database } {
  const client = createClient({ url, authToken });
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
