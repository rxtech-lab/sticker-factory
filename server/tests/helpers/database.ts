import { createDatabase, type Database } from "@/lib/db/client";

/**
 * A private Postgres for one test, held entirely in memory.
 *
 * PGlite is Postgres compiled to WebAssembly, so the CHECK constraints, the partial unique index,
 * and the PL/pgSQL triggers in `drizzle/` are enforced by the same engine that enforces them on
 * Neon — which is the point: a test that passes against a different engine proves less than it
 * looks like it does. The migrations are drizzle's own, applied from the same journal and files
 * `bun run db:migrate` uses, so a test database can never be a schema version ahead or behind.
 */
export async function createTestDatabase(): Promise<{ db: Database; close: () => Promise<void> }> {
  const handle = await createDatabase("pglite:");
  await handle.migrate();
  return { db: handle.db, close: handle.close };
}
