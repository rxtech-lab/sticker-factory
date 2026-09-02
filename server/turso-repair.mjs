// One-off repair for the push-managed Turso database. See turso-repair.sql.
// Run:  bun --env-file=.env turso-repair.mjs
import { createClient } from "@libsql/client";
import { readFileSync } from "node:fs";

const c = createClient({
  url: process.env.TURSO_DATABASE_URL,
  authToken: process.env.TURSO_AUTH_TOKEN,
});

const count = async (t) => Number((await c.execute(`select count(*) as n from ${t}`)).rows[0].n);
const before = { jobs: await count("generation_jobs"), revisions: await count("sticker_revisions") };
console.log("before:", before);

await c.executeMultiple(readFileSync(new URL("./turso-repair.sql", import.meta.url), "utf8"));

const after = { jobs: await count("generation_jobs"), revisions: await count("sticker_revisions") };
console.log("after: ", after);
if (before.jobs !== after.jobs || before.revisions !== after.revisions) {
  throw new Error("ROW COUNT CHANGED — inspect before doing anything else");
}

const cols = (await c.execute("pragma table_info(generation_jobs)")).rows.map((r) => r.name);
console.log("reservation columns:", cols.filter((n) => n.startsWith("reservation")));
const ddl = (await c.execute("select sql from sqlite_master where name='sticker_revisions'")).rows[0].sql;
console.log("apng_asset_id FK present:", /FOREIGN KEY \(apng_asset_id\)/.test(ddl));
console.log("foreign_key_check violations:", (await c.execute("pragma foreign_key_check")).rows.length);
