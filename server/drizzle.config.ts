import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "turso",
  schema: "./lib/db/schema.ts",
  out: "./drizzle",
  // Turso exposes internal MVCC bookkeeping tables in the same schema.
  // Exclude them so drizzle-kit does not try to drop protected system tables.
  tablesFilter: ["!__turso_internal_*"],
  dbCredentials: {
    url: process.env.TURSO_DATABASE_URL ?? "file:local-sticker-factory.db",
    authToken: process.env.TURSO_AUTH_TOKEN,
  },
});
