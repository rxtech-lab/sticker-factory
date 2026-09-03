import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: { "@": fileURLToPath(new URL(".", import.meta.url)) },
  },
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
    // Each database-backed test boots its own PGlite — a WebAssembly Postgres — and the first one
    // in a worker pays for compiling the module on top of that. The default 5s is not enough for
    // the boot plus the work; these are the ceilings for a hang, not an expected duration.
    testTimeout: 30_000,
    hookTimeout: 30_000,
    coverage: {
      provider: "v8",
      reporter: ["text", "json-summary"],
      include: ["lib/**/*.ts", "workflows/**/*.ts"],
    },
  },
});
