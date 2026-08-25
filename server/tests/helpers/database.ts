import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createDatabase, type Database } from "@/lib/db/client";
import { readMigrations } from "@/lib/db/migrations";

export async function createTestDatabase(): Promise<{ db: Database; close: () => Promise<void> }> {
  const directory = await mkdtemp(join(tmpdir(), "sticker-factory-test-"));
  const { client, db } = createDatabase(`file:${join(directory, "test.db")}`);
  for (const migration of await readMigrations()) {
    await client.executeMultiple(migration);
  }
  return {
    db,
    close: async () => {
      client.close();
      await rm(directory, { recursive: true, force: true });
    },
  };
}
