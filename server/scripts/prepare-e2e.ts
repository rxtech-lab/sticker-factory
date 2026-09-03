import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, sep } from "node:path";
import { createDatabase } from "@/lib/db/client";

const url = process.env.DATABASE_URL;
if (!url?.startsWith("pglite:")) throw new Error("E2E requires an explicit pglite: DATABASE_URL");
const dataDirectory = resolve(url.slice("pglite:".length));
const temporaryRoot = resolve(tmpdir()) + sep;
if (!dataDirectory.startsWith(temporaryRoot) || !dataDirectory.includes("sticker-factory-playwright")) {
  throw new Error("Refusing to reset an E2E database outside the guarded temporary path");
}

await rm(dataDirectory, { recursive: true, force: true });
const handle = await createDatabase(url);
await handle.migrate();
// PGlite lets one process hold a data directory at a time, so this has to let go before `next dev`
// opens the same one.
await handle.close();
