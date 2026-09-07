import { neonConfig, Pool } from "@neondatabase/serverless";
import type { ExtractTablesWithRelations } from "drizzle-orm";
import { drizzle } from "drizzle-orm/neon-serverless";
import type { PgDatabase, PgQueryResultHKT } from "drizzle-orm/pg-core";
import * as schema from "@/lib/db/schema";
import { recordSpan } from "@/lib/http/timing";

/**
 * Anything that speaks Postgres against this schema.
 *
 * Written as the driver-agnostic supertype rather than `NeonDatabase` so the same services run
 * against the PGlite instance the test and E2E databases are built on. Every call the codebase
 * makes — `select`, `insert`, `update`, `delete`, `transaction`, `execute` — is on this interface.
 */
export type Database = PgDatabase<
  PgQueryResultHKT,
  typeof schema,
  ExtractTablesWithRelations<typeof schema>
>;

/**
 * The first row of a result, or `undefined`.
 *
 * Stands in for SQLite's `.get()`, which the Postgres builders do not have: `…where(…).then(firstRow)`
 * reads the same way and means the same thing. Like `.get()`, it adds no `LIMIT` — a query that can
 * match more than one row still fetches them all, and still answers with the first.
 */
export function firstRow<T>(rows: T[]): T | undefined {
  return rows[0];
}

export interface DatabaseHandle {
  db: Database;
  /**
   * Runs a whole SQL script — several statements, dollar-quoted function bodies and all.
   *
   * `db.execute` cannot: drizzle always sends a parameter list, which puts the driver on the
   * extended query protocol, and that accepts exactly one statement. Migrations need the simple
   * protocol, so they go through the driver underneath instead.
   */
  exec: (script: string) => Promise<void>;
  /**
   * One parameterized statement, outside the query builder.
   *
   * For the things drizzle deliberately does not model: `ALTER TABLE ... DISABLE TRIGGER`,
   * `setval` on an identity sequence, a bulk copy that names its columns as strings.
   */
  query: (text: string, values?: unknown[]) => Promise<Record<string, unknown>[]>;
  /**
   * Applies whatever in `drizzle/` has not run yet, tracked in `drizzle.__drizzle_migrations`.
   *
   * The same journal, files, and ledger `bun run db:migrate` uses — that is `drizzle-kit migrate`
   * against Neon, and this is the programmatic form of it for the databases the CLI cannot reach:
   * the in-memory one each test file opens, and the Playwright run's.
   */
  migrate: () => Promise<void>;
  close: () => Promise<void>;
}

/** Where both migrators look. Relative to the server package, which is every caller's cwd. */
const MIGRATIONS_FOLDER = "drizzle";

let singleton: DatabaseHandle | undefined;
let testDatabase: Database | undefined;
let webSocketsConfigured = false;

/**
 * Reports every round trip as a `db` span on the in-flight request.
 *
 * Wrapping the driver rather than the query builder means round trips are counted wherever they
 * originate — services, workflow steps, idempotency — so a request log can be compared against the
 * total and the difference attributed to something other than the database.
 */
function instrumentQuery<T extends { query: (...args: never[]) => Promise<unknown> }>(target: T): T {
  const original = target.query.bind(target) as (...args: unknown[]) => Promise<unknown>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (target as any).query = async (...args: unknown[]) => {
    const startedAt = performance.now();
    try {
      return await original(...args);
    } finally {
      recordSpan("db", performance.now() - startedAt);
    }
  };
  return target;
}

/**
 * Neon's driver reaches the database over a WebSocket, which Node does not have natively.
 *
 * The import is dynamic and cached so the `ws` dependency is only pulled in when a Neon URL is
 * actually opened — a PGlite-backed test run never loads it, and a real browser/edge runtime uses
 * its own `WebSocket` rather than this shim.
 */
async function configureWebSockets(): Promise<void> {
  if (webSocketsConfigured) return;
  webSocketsConfigured = true;
  if (typeof WebSocket !== "undefined") {
    neonConfig.webSocketConstructor = WebSocket;
    return;
  }
  const { default: ws } = await import("ws");
  neonConfig.webSocketConstructor = ws;
}

/**
 * A PGlite-backed database, for tests and the Playwright run.
 *
 * PGlite is Postgres itself compiled to WebAssembly, so the CHECK constraints, partial unique
 * index, and PL/pgSQL triggers in `drizzle/` all behave exactly as they do on Neon — which is the
 * whole point of not substituting a different engine underneath the tests.
 *
 * `pglite:` with nothing after it is in-memory; anything else is a data directory. Only one
 * connection may hold a directory at a time, which is why the E2E preparer closes before the dev
 * server starts.
 */
async function createPgliteDatabase(url: string): Promise<DatabaseHandle> {
  const [{ PGlite }, { drizzle: drizzlePglite }, { migrate }] = await Promise.all([
    import("@electric-sql/pglite"),
    import("drizzle-orm/pglite"),
    import("drizzle-orm/pglite/migrator"),
  ]);
  const dataDir = url.slice("pglite:".length);
  // Next.js route/workflow bundles can load separate instances of this module. A disk-backed
  // PGlite directory must still have exactly one engine; multiple engines retain stale buffers.
  // In-memory databases stay independent so each unit/integration test owns its fixture.
  const globalPglite = globalThis as typeof globalThis & {
    stickerFactoryPglite?: Map<string, InstanceType<typeof PGlite>>;
  };
  const clients = globalPglite.stickerFactoryPglite ??= new Map<string, InstanceType<typeof PGlite>>();
  const client = dataDir && clients.has(dataDir)
    ? clients.get(dataDir)!
    : instrumentQuery(new PGlite(dataDir || undefined));
  if (dataDir) clients.set(dataDir, client);
  const db = drizzlePglite(client, { schema });
  return {
    db: db as unknown as Database,
    migrate: () => migrate(db, { migrationsFolder: MIGRATIONS_FOLDER }),
    exec: async (script) => void await client.exec(script),
    query: async (text, values) =>
      (await client.query<Record<string, unknown>>(text, values as unknown[])).rows,
    close: async () => {
      if (dataDir && clients.get(dataDir) === client) clients.delete(dataDir);
      await client.close();
    },
  };
}

async function createNeonDatabase(url: string): Promise<DatabaseHandle> {
  await configureWebSockets();
  const { migrate } = await import("drizzle-orm/neon-serverless/migrator");
  const pool = instrumentQuery(new Pool({ connectionString: url }));
  const db = drizzle(pool, { schema });
  return {
    db,
    migrate: () => migrate(db, { migrationsFolder: MIGRATIONS_FOLDER }),
    exec: async (script) => void await pool.query(script),
    query: async (text, values) => (await pool.query(text, values as unknown[])).rows,
    close: () => pool.end(),
  };
}

/** Opens a database from a connection string, choosing the driver the scheme names. */
export async function createDatabase(url: string): Promise<DatabaseHandle> {
  return url.startsWith("pglite:") ? createPgliteDatabase(url) : createNeonDatabase(url);
}

export function databaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is required at runtime");
  return url;
}

/**
 * The process-wide database.
 *
 * Opening is asynchronous because both drivers are loaded on demand — Neon's WebSocket shim and
 * PGlite's WebAssembly module are each several hundred kilobytes that the other never needs. The
 * promise is memoized, so concurrent requests during a cold start share one pool rather than
 * racing to build several.
 */
let opening: Promise<DatabaseHandle> | undefined;

export async function getDatabase(): Promise<Database> {
  if (testDatabase) return testDatabase;
  if (singleton) return singleton.db;
  opening ??= createDatabase(databaseUrl()).then((handle) => {
    singleton = handle;
    return handle;
  });
  return (await opening).db;
}

export async function resetDatabaseForTests(): Promise<void> {
  const handle = singleton;
  singleton = undefined;
  opening = undefined;
  testDatabase = undefined;
  await handle?.close();
}

export function setDatabaseForTests(db?: Database): void {
  testDatabase = db;
}
