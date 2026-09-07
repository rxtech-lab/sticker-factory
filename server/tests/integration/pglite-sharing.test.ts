import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, it } from "vitest";
import { createDatabase } from "@/lib/db/client";

it("shares live disk-backed Postgres state between independently opened route handles", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sticker-pglite-sharing-"));
  const [first, second] = await Promise.all([
    createDatabase(`pglite:${directory}`),
    createDatabase(`pglite:${directory}`),
  ]);
  try {
    // Both handles exist before the first write, just as separately compiled Next.js routes do.
    await first.exec("CREATE TABLE shared_probe (id integer PRIMARY KEY, value text NOT NULL)");
    await first.query("INSERT INTO shared_probe VALUES ($1, $2)", [1, "created"]);
    expect(await second.query("SELECT value FROM shared_probe")).toEqual([{ value: "created" }]);
    await second.query("UPDATE shared_probe SET value = $1 WHERE id = $2", ["updated", 1]);
    expect(await first.query("SELECT value FROM shared_probe")).toEqual([{ value: "updated" }]);
  } finally {
    // The handles share one engine, so closing it releases the directory for both.
    await first.close();
    await rm(directory, { recursive: true, force: true });
  }
});
