import { eq } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { firstRow, type Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";

const MAX_ENSURED_ENTRIES = 10_000;

/**
 * User rows already inserted (or currently being inserted), per database.
 *
 * Keyed on the `Database` so a swapped connection — the per-test in-memory databases, most of all —
 * never inherits another one's work. Keeping the promise coalesces concurrent cold requests for
 * the same user into one database statement.
 */
const ensured = new WeakMap<Database, Map<string, Promise<void>>>();

function entriesFor(db: Database): Map<string, Promise<void>> {
  let entries = ensured.get(db);
  if (!entries) {
    entries = new Map();
    ensured.set(db, entries);
  }
  return entries;
}

/**
 * Makes sure a row exists for the caller so the owner foreign keys resolve.
 *
 * OAuth remains the source of truth for profile data, so this database row stores only the stable
 * subject id. Each server instance performs one conflict-tolerant insert per user and never reads
 * or updates email/display-name fields.
 */
export async function ensureUser(db: Database, principal: ApiPrincipal): Promise<void> {
  const entries = entriesFor(db);
  const existing = entries.get(principal.sub);
  if (existing) return existing;

  // Bounded so a long-lived instance serving many principals cannot grow without limit. Insertion
  // order makes the oldest key the natural eviction target.
  if (entries.size >= MAX_ENSURED_ENTRIES) {
    const oldest = entries.keys().next();
    if (!oldest.done) entries.delete(oldest.value);
  }

  const insertion = db.insert(users)
    .values({ id: principal.sub })
    .onConflictDoNothing({ target: users.id })
    .then(() => undefined);
  entries.set(principal.sub, insertion);
  try {
    await insertion;
  } catch (error) {
    // Do not cache failures: the next request should be allowed to retry.
    if (entries.get(principal.sub) === insertion) entries.delete(principal.sub);
    throw error;
  }
}

export async function getUser(db: Database, id: string) {
  return db.select().from(users).where(eq(users.id, id)).then(firstRow);
}
