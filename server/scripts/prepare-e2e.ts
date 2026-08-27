import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, sep } from "node:path";
import { createClient } from "@libsql/client";
import { readMigrations } from "@/lib/db/migrations";

const url = process.env.TURSO_DATABASE_URL;
if (!url?.startsWith("file:")) throw new Error("E2E requires an explicit file: TURSO_DATABASE_URL");
const databasePath = resolve(url.slice("file:".length));
const temporaryRoot = resolve(tmpdir()) + sep;
if (!databasePath.startsWith(temporaryRoot) || !databasePath.includes("sticker-factory-playwright")) {
  throw new Error("Refusing to reset an E2E database outside the guarded temporary path");
}

await rm(databasePath, { force: true });
const client = createClient({ url });
// Every migration, not just the first: the Playwright database has to match what `db:migrate` and
// the unit-test helper produce, or a table added by a later migration is simply missing here.
for (const migration of await readMigrations()) {
  await client.executeMultiple(migration);
}
await client.close();
