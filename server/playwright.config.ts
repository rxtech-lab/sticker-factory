import { tmpdir } from "node:os";
import { join } from "node:path";
import { defineConfig } from "@playwright/test";

const databaseUrl = `file:${join(tmpdir(), "sticker-factory-playwright.db")}`;

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
  webServer: {
    command: "bun run dev:e2e",
    url: "http://127.0.0.1:3105",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    env: {
      ...process.env,
      TURSO_DATABASE_URL: databaseUrl,
      STICKER_FACTORY_E2E: "true",
      STICKER_FACTORY_E2E_USER_ID: "playwright-user",
      STICKER_FACTORY_E2E_KEY: "local-playwright-seed",
      STICKER_FACTORY_MOCK_SERVICES: "true",
      AUTH_SECRET: "playwright-only-secret-that-is-never-deployed",
    },
  },
});
