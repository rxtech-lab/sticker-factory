import { readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, sep } from "node:path";
import { createClient } from "@libsql/client";

const url = process.env.TURSO_DATABASE_URL;
if (!url?.startsWith("file:")) throw new Error("E2E requires an explicit file: TURSO_DATABASE_URL");
const databasePath = resolve(url.slice("file:".length));
const temporaryRoot = resolve(tmpdir()) + sep;
if (!databasePath.startsWith(temporaryRoot) || !databasePath.includes("sticker-factory-playwright")) {
  throw new Error("Refusing to reset an E2E database outside the guarded temporary path");
}

await rm(databasePath, { force: true });
const client = createClient({ url });
await client.executeMultiple(await readFile(resolve("drizzle/0001_sticker_factory.sql"), "utf8"));
await client.close();
