import { defineConfig, devices } from "@playwright/test";
export default defineConfig({
  testDir: "./e2e", testMatch: "tutorial.spec.ts", workers: 1,
  timeout: 45_000, use: { baseURL: "http://127.0.0.1:3117", trace: "retain-on-failure" },
  projects: [{ name: "tutorial-webkit", use: { ...devices["iPhone 13"], browserName: "webkit" } }],
  webServer: { command: "bun x next dev -p 3117", url: "http://127.0.0.1:3117/tutorial/en", reuseExistingServer: true,
    env: { STICKER_FACTORY_TUTORIAL_PREVIEW: "true" } },
});
