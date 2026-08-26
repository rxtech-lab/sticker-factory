import { readdir, readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

/**
 * Every migration file in `drizzle/`, in lexical order.
 *
 * Shared by the migrate script and the test database helper so a fresh test database and a real
 * one can never end up on different schema versions.
 */
export async function readMigrations(directory = resolve("drizzle")): Promise<string[]> {
  const names = (await readdir(directory)).filter((name) => name.endsWith(".sql")).sort();
  return Promise.all(names.map((name) => readFile(join(directory, name), "utf8")));
}
