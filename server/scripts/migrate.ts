import { createClient } from "@libsql/client";
import { readMigrations } from "@/lib/db/migrations";

const url = process.env.TURSO_DATABASE_URL ?? "file:local-sticker-factory.db";
const client = createClient({ url, authToken: process.env.TURSO_AUTH_TOKEN });

for (const migration of await readMigrations()) {
  await client.executeMultiple(migration);
}

await client.close();
console.log(`Applied Sticker Factory migrations to ${url}`);
