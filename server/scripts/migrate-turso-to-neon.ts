/**
 * Copies the Turso database into Postgres, once.
 *
 * This is the data half of the move off libSQL; `bun run db:migrate` is the schema half and must
 * have run first. It is written to be re-runnable: every table is emptied before it is filled, so a
 * failed run is fixed by fixing the cause and running it again rather than by unpicking half a copy.
 *
 * Three shape changes happen on the way across, and they are the first reason this is a script
 * rather than a `pg_dump`:
 *
 *   - Instants were epoch milliseconds in an INTEGER column and are now `timestamptz`.
 *   - JSON documents were TEXT holding serialized JSON and are now `jsonb`.
 *   - Booleans were 0/1 and are now `boolean`.
 *
 * The second reason is referential integrity. SQLite only enforces foreign keys when a connection
 * asks it to, and this database's did not, so it accumulated rows pointing at stickers and jobs
 * that had since been deleted — 4,247 dangling references when the copy was written. Postgres does
 * enforce them, so each row is resolved against what has actually been imported, applying the very
 * rule the foreign key declares: a missing parent behind a `NOT NULL` column means `ON DELETE
 * CASCADE`, so the row is dropped; behind a nullable one it means `ON DELETE SET NULL`, so the row
 * is kept and the pointer cleared. The result is the state the database would already have been in
 * had the cascades ever run. Every row dropped this way is unreachable from the application.
 *
 * Tables are filled in foreign-key order and emptied in its reverse. `stickers.active_revision_id`
 * and `plans.supersedes_id` point forwards, so they are held back and written in a second pass.
 */
import { createClient, type Row } from "@libsql/client";
import { createDatabase, databaseUrl } from "@/lib/db/client";

type ColumnKind = "text" | "integer" | "double" | "timestamp" | "boolean" | "json";

interface Reference {
  column: string;
  /** The table whose imported ids this column must name. */
  parent: string;
  /**
   * `true` where the column is `NOT NULL` — a missing parent has nowhere to go, so the row is
   * dropped, which is what the foreign key's `ON DELETE CASCADE` would have done. `false` where it
   * is nullable, and `ON DELETE SET NULL` says to keep the row and clear the pointer.
   */
  required: boolean;
}

interface TableSpec {
  name: string;
  /** The primary key, where later tables need to check their references against it. */
  id?: string;
  columns: Record<string, ColumnKind>;
  references?: Reference[];
  /** Columns pointing at a table filled later, written by a second `UPDATE` once it exists. */
  deferred?: string[];
}

const TIMESTAMPS = {
  created_at: "timestamp",
  updated_at: "timestamp",
} as const satisfies Record<string, ColumnKind>;

const required = (column: string, parent: string): Reference => ({ column, parent, required: true });
const nullable = (column: string, parent: string): Reference => ({ column, parent, required: false });

/** The renditions a revision points at, every one of them a nullable reference to `assets`. */
const REVISION_ASSET_COLUMNS = [
  "master_asset_id", "preview_asset_id", "png_asset_id", "gif_asset_id", "apng_asset_id",
  "mp4_asset_id", "system_asset_id", "attachment_medium_asset_id", "attachment_small_asset_id",
];

/**
 * Every table, in the order a foreign key allows them to be filled.
 *
 * The column lists are explicit rather than read from `sqlite_master` so that a column that exists
 * in Turso but not in the Postgres schema — or the reverse — fails loudly here instead of being
 * silently dropped or defaulted.
 */
const TABLES: TableSpec[] = [
  {
    name: "users",
    id: "id",
    columns: { id: "text", email: "text", display_name: "text", ...TIMESTAMPS },
  },
  {
    name: "stickers",
    id: "id",
    columns: {
      id: "text", owner_id: "text", title: "text", kind: "text", status: "text",
      active_revision_id: "text", ...TIMESTAMPS, deleted_at: "timestamp",
    },
    references: [required("owner_id", "users")],
    // Revisions are filled later, and a trigger checks this names one of *this* sticker's.
    deferred: ["active_revision_id"],
  },
  {
    name: "chat_threads",
    id: "id",
    columns: { id: "text", sticker_id: "text", owner_id: "text", ...TIMESTAMPS },
    references: [required("sticker_id", "stickers"), required("owner_id", "users")],
  },
  {
    name: "generation_jobs",
    id: "id",
    columns: {
      id: "text", owner_id: "text", sticker_id: "text", source_message_id: "text", kind: "text",
      quick: "boolean", prior_sticker_status: "text", state: "text", workflow_run_id: "text",
      reservation_id: "text", reservation_amount: "integer",
      api_text_cost_nanodollars: "integer", api_image_cost_nanodollars: "integer",
      api_image_points: "integer", api_video_cost_nanodollars: "integer",
      api_video_points: "integer", attempts: "integer", error_code: "text", error_message: "text",
      ...TIMESTAMPS, completed_at: "timestamp",
    },
    references: [required("owner_id", "users"), required("sticker_id", "stickers")],
  },
  {
    name: "chat_messages",
    id: "id",
    columns: {
      id: "text", thread_id: "text", owner_id: "text", role: "text", kind: "text",
      content: "text", target_layer_id: "text", base_revision_id: "text",
      image_placement: "text", sequence: "integer", revision_id: "text", job_id: "text",
      status: "text", plan_id: "text", plan_revision: "integer", created_at: "timestamp",
    },
    references: [
      required("thread_id", "chat_threads"),
      required("owner_id", "users"),
      nullable("job_id", "generation_jobs"),
    ],
    // `plans` is filled after this table, because a plan names the message it was first shown in.
    deferred: ["plan_id"],
  },
  {
    name: "assets",
    id: "id",
    columns: {
      id: "text", owner_id: "text", sticker_id: "text", kind: "text", state: "text",
      r2_key: "text", mime_type: "text", byte_size: "integer", width: "integer",
      height: "integer", frame_count: "integer", duration_seconds: "double", fps: "double",
      sha256: "text", has_alpha: "boolean", original_filename: "text",
      created_at: "timestamp", ready_at: "timestamp",
      sequence_columns: "integer", sequence_rows: "integer",
    },
    references: [required("owner_id", "users"), nullable("sticker_id", "stickers")],
  },
  {
    name: "sticker_revisions",
    id: "id",
    columns: {
      id: "text", sticker_id: "text", parent_revision_id: "text", source_message_id: "text",
      kind: "text", candidate_state: "text", document_json: "json", master_asset_id: "text",
      preview_asset_id: "text", png_asset_id: "text", gif_asset_id: "text", apng_asset_id: "text",
      mp4_asset_id: "text", system_asset_id: "text", attachment_medium_asset_id: "text",
      attachment_small_asset_id: "text", created_at: "timestamp", decided_at: "timestamp",
    },
    references: [
      required("sticker_id", "stickers"),
      nullable("source_message_id", "chat_messages"),
      ...REVISION_ASSET_COLUMNS.map((column) => nullable(column, "assets")),
    ],
  },
  {
    name: "chat_attachments",
    columns: {
      message_id: "text", asset_id: "text", kind: "text", target_layer_id: "text",
      position: "integer",
    },
    references: [required("message_id", "chat_messages"), required("asset_id", "assets")],
  },
  {
    name: "generation_events",
    columns: {
      id: "integer", job_id: "text", owner_id: "text", type: "text", data_json: "json",
      created_at: "timestamp",
    },
    references: [required("job_id", "generation_jobs"), required("owner_id", "users")],
  },
  {
    name: "plans",
    id: "id",
    columns: {
      id: "text", owner_id: "text", sticker_id: "text", thread_id: "text", message_id: "text",
      plan_json: "json", state: "text", revision: "integer", supersedes_id: "text",
      job_id: "text", concept_asset_id: "text", decision_reason: "text",
      ...TIMESTAMPS, decided_at: "timestamp",
    },
    references: [
      required("owner_id", "users"),
      required("sticker_id", "stickers"),
      required("thread_id", "chat_threads"),
      required("message_id", "chat_messages"),
      nullable("job_id", "generation_jobs"),
      nullable("concept_asset_id", "assets"),
    ],
    // A superseded plan may be named by one written after it, so the link waits for both rows.
    deferred: ["supersedes_id"],
  },
  {
    name: "creator_profiles",
    columns: {
      user_id: "text", handle: "text", display_name: "text", bio: "text",
      avatar_asset_id: "text", payout_status: "text", payout_provider: "text",
      payout_account_ref: "text", ...TIMESTAMPS,
    },
    references: [required("user_id", "users"), nullable("avatar_asset_id", "assets")],
  },
  {
    name: "sticker_packs",
    id: "id",
    columns: {
      id: "text", creator_id: "text", slug: "text", title: "text", summary: "text",
      state: "text", cover_sticker_id: "text", item_count: "integer", install_count: "integer",
      install_total: "integer", monetization: "text", price_cents: "integer", currency: "text",
      revenue_share_bps: "integer", published_at: "timestamp", ...TIMESTAMPS,
    },
    references: [required("creator_id", "users"), nullable("cover_sticker_id", "stickers")],
  },
  {
    name: "sticker_pack_items",
    columns: {
      pack_id: "text", sticker_id: "text", position: "integer", added_at: "timestamp",
    },
    references: [required("pack_id", "sticker_packs"), required("sticker_id", "stickers")],
  },
  {
    name: "pack_installs",
    columns: {
      pack_id: "text", user_id: "text", state: "text", position: "integer",
      acquisition: "text", price_cents_paid: "integer", order_ref: "text",
      installed_at: "timestamp", uninstalled_at: "timestamp",
    },
    references: [required("pack_id", "sticker_packs"), required("user_id", "users")],
  },
  {
    name: "device_tokens",
    columns: {
      token: "text", user_id: "text", platform: "text", environment: "text", bundle_id: "text",
      app_version: "text", ...TIMESTAMPS, last_seen_at: "timestamp",
      disabled_at: "timestamp", disabled_reason: "text",
    },
    references: [required("user_id", "users")],
  },
  {
    name: "idempotency_keys",
    columns: {
      owner_id: "text", operation: "text", key: "text", request_hash: "text",
      response_status: "integer", response_json: "json", created_at: "timestamp",
      expires_at: "timestamp",
    },
    references: [required("owner_id", "users")],
  },
];

/**
 * Triggers that must not fire while the copy runs, as `[table, trigger]`.
 *
 * The counters because `install_count`, `install_total` and `item_count` come across as the values
 * Turso already holds — leaving them on would count every install twice — and the two guards
 * because they judge rows against live state. An asset belonging to a sticker that was mid-delete
 * when the snapshot was taken is history now, and refusing to copy it would quietly lose it.
 */
/**
 * Rows per `INSERT`.
 *
 * A statement per row means a round trip per row, and against a database several thousand
 * kilometres away that is both slow and long enough for the WebSocket to be dropped mid-copy —
 * which is exactly how the first attempt at this failed. Multi-row `VALUES` turns ~6,000 round
 * trips into a few dozen. The ceiling is Postgres' 65,535 parameters per statement; the widest
 * table here has 22 columns, so this leaves an order of magnitude of headroom.
 */
const ROWS_PER_INSERT = 200;

const SUSPENDED_TRIGGERS: [table: string, trigger: string][] = [
  ["pack_installs", "pack_installs_count_insert"],
  ["sticker_pack_items", "sticker_pack_items_count_insert"],
  ["assets", "assets_reject_deleting_sticker_insert"],
  ["sticker_pack_items", "sticker_pack_items_require_creator_ownership_insert"],
];

function convert(value: Row[string], kind: ColumnKind): unknown {
  if (value === null || value === undefined) return null;
  switch (kind) {
    case "timestamp":
      // Epoch milliseconds, as an INTEGER column held them.
      return new Date(Number(value));
    case "boolean":
      return Number(value) !== 0;
    case "json":
      // libSQL hands these back as the TEXT they were stored as; `pg` serializes an object into
      // `jsonb`, so the round trip is parse-then-reserialize rather than a raw passthrough.
      return typeof value === "string" ? JSON.parse(value) : value;
    case "integer":
      return typeof value === "bigint" ? Number(value) : value;
    case "double":
      return Number(value);
    default:
      return value;
  }
}

const sourceUrl = process.env.TURSO_DATABASE_URL;
if (!sourceUrl) throw new Error("TURSO_DATABASE_URL is required");
const source = createClient({ url: sourceUrl, authToken: process.env.TURSO_AUTH_TOKEN });

const target = await createDatabase(databaseUrl());
const run = target.query;

/** The primary keys actually imported, per table, for the reference checks to resolve against. */
const imported = new Map<string, Set<string>>();
const dropped: Record<string, number> = {};
const cleared: Record<string, number> = {};

function note(counter: Record<string, number>, key: string): void {
  counter[key] = (counter[key] ?? 0) + 1;
}

/**
 * Applies each reference's own `ON DELETE` rule to a row whose parent did not survive.
 *
 * Returns the row with cleared pointers, or `undefined` where a required parent is missing and the
 * row therefore cannot exist.
 */
function resolveReferences(table: TableSpec, row: Row): Row | undefined {
  if (!table.references) return row;
  const resolved: Row = { ...row };
  for (const { column, parent, required: isRequired } of table.references) {
    const value = resolved[column];
    if (value === null || value === undefined) continue;
    if (imported.get(parent)?.has(String(value))) continue;
    if (isRequired) {
      note(dropped, `${table.name} (${column} -> ${parent})`);
      return undefined;
    }
    resolved[column] = null;
    note(cleared, `${table.name}.${column}`);
  }
  return resolved;
}

console.log(`Copying ${TABLES.length} tables into ${databaseUrl().replace(/:[^:@/]*@/, ":***@")}\n`);

// Emptying in reverse order keeps every delete inside its own table's foreign keys, and makes a
// re-run of this script a clean overwrite rather than a pile-up of duplicate-key failures.
for (const table of [...TABLES].reverse()) {
  await run(`DELETE FROM "${table.name}"`);
}

for (const [table, trigger] of SUSPENDED_TRIGGERS) {
  await run(`ALTER TABLE "${table}" DISABLE TRIGGER ${trigger}`);
}

for (const table of TABLES) {
  const names = Object.keys(table.columns);
  const rows = (await source.execute(
    `SELECT ${names.map((name) => `"${name}"`).join(", ")} FROM "${table.name}"`,
  )).rows;

  const deferred = new Set(table.deferred ?? []);
  const inserted = names.filter((name) => !deferred.has(name));
  const into = `INSERT INTO "${table.name}" (${inserted.map((n) => `"${n}"`).join(", ")}) VALUES `;

  const survivors = rows.map((row) => resolveReferences(table, row)).filter((row) => row !== undefined);
  if (table.id) {
    imported.set(table.name, new Set(survivors.map((row) => String(row[table.id!]))));
  }

  for (let offset = 0; offset < survivors.length; offset += ROWS_PER_INSERT) {
    const chunk = survivors.slice(offset, offset + ROWS_PER_INSERT);
    const values: unknown[] = [];
    const tuples = chunk.map((row) => `(${inserted.map((name) => {
      values.push(convert(row[name], table.columns[name]));
      return `$${values.length}`;
    }).join(", ")})`);
    await run(into + tuples.join(", "), values);
  }

  const skipped = rows.length - survivors.length;
  console.log(`  ${String(survivors.length).padStart(6)}  ${table.name}${skipped ? `  (${skipped} dropped)` : ""}`);
}

// Second pass for the columns held back above, now that everything they point at exists. They are
// resolved exactly like the rest: a pointer at a row that did not survive is simply not written.
for (const table of TABLES) {
  const deferred = table.deferred;
  if (!deferred?.length) continue;
  const key = table.id;
  if (!key) throw new Error(`${table.name} defers ${deferred.join(", ")} but names no key column`);

  const parents: Record<string, string> = {
    active_revision_id: "sticker_revisions",
    plan_id: "plans",
    supersedes_id: "plans",
  };
  const rows = (await source.execute(
    `SELECT ${[key, ...deferred].map((name) => `"${name}"`).join(", ")} FROM "${table.name}"
     WHERE ${deferred.map((name) => `"${name}" IS NOT NULL`).join(" OR ")}`,
  )).rows;

  let linked = 0;
  for (const row of rows) {
    if (!imported.get(table.name)?.has(String(row[key]))) continue;
    const writable = deferred.filter((name) => {
      const value = row[name];
      return value !== null && imported.get(parents[name])?.has(String(value));
    });
    if (!writable.length) continue;
    const assignments = writable.map((name, index) => `"${name}" = $${index + 1}`).join(", ");
    await run(
      `UPDATE "${table.name}" SET ${assignments} WHERE "${key}" = $${writable.length + 1}`,
      [...writable.map((name) => convert(row[name], table.columns[name])), row[key]],
    );
    linked += 1;
  }
  console.log(`  ${String(linked).padStart(6)}  ${table.name} (${deferred.join(", ")})`);
}

for (const [table, trigger] of SUSPENDED_TRIGGERS) {
  await run(`ALTER TABLE "${table}" ENABLE TRIGGER ${trigger}`);
}

// `generation_events.id` came across with its original values, so the identity sequence has to be
// moved past them or the next insert collides with a row that is already there.
await run(`
  SELECT setval(
    pg_get_serial_sequence('generation_events', 'id'),
    GREATEST((SELECT COALESCE(MAX(id), 0) FROM generation_events), 1),
    (SELECT COUNT(*) FROM generation_events) > 0
  )
`);

await source.close();
await target.close();

const report = (label: string, counter: Record<string, number>) => {
  const entries = Object.entries(counter).sort(([, a], [, b]) => b - a);
  if (!entries.length) return;
  console.log(`\n${label}`);
  for (const [key, value] of entries) console.log(`  ${String(value).padStart(6)}  ${key}`);
};
report("Dropped — required parent was already deleted (ON DELETE CASCADE):", dropped);
report("Cleared — optional parent was already deleted (ON DELETE SET NULL):", cleared);
