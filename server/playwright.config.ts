import { tmpdir } from "node:os";
import { join } from "node:path";
import { defineConfig } from "@playwright/test";

// A PGlite data directory rather than a server: real Postgres, no daemon to install or start, and
// `prepare-e2e` wipes it before every run. It is opened by `next dev`, so nothing else may hold it.
const databaseUrl = `pglite:${join(tmpdir(), "sticker-factory-playwright")}`;

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: "http://127.0.0.1:3105",
    trace: "retain-on-failure",
  },
  timeout: 60_000,
  webServer: [{
    command: "bun e2e/support/auth-server.ts",
    url: "http://127.0.0.1:3106/.well-known/jwks.json",
    reuseExistingServer: false,
  }, {
    command: "bun run dev:e2e",
    url: "http://127.0.0.1:3105",
    reuseExistingServer: false,
    timeout: 120_000,
    env: {
      ...process.env,
      DATABASE_URL: databaseUrl,
      WORKFLOW_LOCAL_DATA_DIR: join(databaseUrl.slice("pglite:".length), "workflows"),
      WORKFLOW_LOCAL_BASE_URL: "http://127.0.0.1:3105",
      AUTH_ISSUER: "http://127.0.0.1:3106",
      RXLAB_ALLOWED_CLIENT_IDS: "e2e-client",
      AUTH_CLIENT_ID: "e2e-client",
      IOS_OAUTH_CLIENT_ID: "",
      RX_SUBSCRIPTION_URL: "",
      RX_SUBSCRIPTION_API_KEY: "",
      STICKER_FACTORY_E2E: "true",
      STICKER_FACTORY_E2E_USER_ID: "playwright-user",
      STICKER_FACTORY_E2E_KEY: "local-playwright-seed",
      STICKER_FACTORY_MOCK_SERVICES: "true",
      AUTH_SECRET: "playwright-only-secret-that-is-never-deployed",
    },
  }],
});
