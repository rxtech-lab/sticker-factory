// Read-only safety net: dump the table the repair rebuilds, plus full DDL.
import { createClient } from "@libsql/client";
import { writeFileSync } from "node:fs";
const c = createClient({ url: process.env.TURSO_DATABASE_URL, authToken: process.env.TURSO_AUTH_TOKEN });
const out = process.argv[2];
const rows = (await c.execute("select * from sticker_revisions")).rows.map((r) => ({ ...r }));
const jobs = (await c.execute("select * from generation_jobs")).rows.map((r) => ({ ...r }));
const ddl = (await c.execute("select name, sql from sqlite_master where sql is not null")).rows.map((r) => ({ ...r }));
writeFileSync(out, JSON.stringify({ takenFor: "turso-repair", sticker_revisions: rows, generation_jobs: jobs, ddl }, null, 2));
console.log(`backed up sticker_revisions=${rows.length} generation_jobs=${jobs.length} objects=${ddl.length} -> ${out}`);
