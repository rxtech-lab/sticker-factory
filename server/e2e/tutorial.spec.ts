import { expect, test } from "@playwright/test";
import { chapters, tutorialLocales } from "../lib/tutorial/catalog";

test("all chapters are public, localized, and have one visible step", async ({ page }) => {
  for (const locale of tutorialLocales) {
    await page.goto(`/tutorial/${locale}`);
    await expect(page.locator(".tutorial-chapter")).toHaveCount(8);
    await expect(page.locator(".site-header")).toHaveCount(0);
    await expect(page.locator(".site-footer")).toHaveCount(0);
    await expect(page.locator("main")).toHaveAttribute("lang", locale);
    for (const chapter of chapters) {
      await page.goto(`/tutorial/${locale}/${chapter.id}`);
      await expect(page.locator("h1")).toHaveText(chapter.titles[locale]);
      await expect(page.locator(".tutorial-step:not([hidden])")).toHaveCount(1);
      await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", chapter.steps[0]);
    }
  }
});
test("reading progress, completion and language changes keep stable locations", async ({ page }) => {
  await page.goto("/tutorial/en/static?step=describe");
  await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", "describe");
  await page.getByRole("button", { name: "Next →", exact: true }).click();
  await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", "references");
  await page.locator("select").selectOption("zh-HK");
  await expect(page).toHaveURL(/zh-HK\/static\?step=references/);
  await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", "references");
  await page.getByRole("button", { name: "下一步 →", exact: true }).click();
  await page.getByRole("button", { name: "完成章節", exact: true }).click();
  await expect(page.locator(".tutorial-finished")).toBeVisible();
  await expect(page.locator(".tutorial-finished a")).toHaveAttribute("href", "/tutorial/zh-HK/animated");
  await page.goto("/tutorial/zh-HK");
  await expect(page.locator(".tutorial-continue")).toHaveAttribute("href", "/tutorial/zh-HK/static?step=review");
  await page.locator(".tutorial-continue").click();
  await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", "review");
});
test("feature links select the current lesson and invalid routes are contained", async ({ page }) => {
  await page.goto("/tutorial/en/controllable?step=controls");
  await expect(page.locator(".tutorial-action a")).toHaveAttribute("href", "stickerfactory://open/sticker?action=controls");
  await page.goto("/tutorial/en/finish?step=export");
  await expect(page.locator(".tutorial-action a")).toHaveAttribute("href", "stickerfactory://open/sticker?action=export");
  await page.goto("/tutorial/fr/static?step=unknown");
  await expect(page).toHaveURL(/\/tutorial\/en\/static/);
  await expect(page.locator(".tutorial-step:not([hidden])")).toHaveAttribute("data-step", "choose");
  const missing = await page.goto("/tutorial/en/does-not-exist");
  expect(missing?.status()).toBe(404);
});
test("media is readable and reduced motion uses a static poster", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/tutorial/en/controllable?step=controls");
  await expect(page.locator(".tutorial-step:not([hidden]) .tutorial-play")).toHaveCount(0);
  await expect(page.locator(".tutorial-step:not([hidden]) img")).toHaveAttribute("src", /controls-20260916\.webp/);
  await page.setViewportSize({ width: 320, height: 700 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
});

test("native tutorial endpoint is public, localized and data-only", async ({ request }) => {
  for (const locale of [...tutorialLocales, "fr"]) {
    const response = await request.get(`/api/v1/tutorial/${locale}`);
    expect(response.status()).toBe(200);
    expect(response.headers()["content-type"]).toContain("application/json");
    expect(response.headers()["set-cookie"]).toBeUndefined();
    const content = await response.json();
    expect(content.version).toBe(1);
    expect(content.locale).toBe(locale === "fr" ? "en" : locale);
    expect(content.chapters).toHaveLength(8);
    for (const chapter of content.chapters) for (const step of chapter.steps) {
      expect(step.action).toMatch(/^stickerfactory:\/\/open\//);
      expect(step.blocks.length).toBeGreaterThan(0);
    }
  }
});

test("every refreshed tutorial image loads from its new URL", async ({ page, request }) => {
  for (const locale of tutorialLocales) {
    const response = await request.get(`/api/v1/tutorial/${locale}`);
    const document = await response.json();
    const posters = new Set<string>();
    for (const chapter of document.chapters) for (const step of chapter.steps) for (const block of step.blocks) {
      if (block.type !== "media") continue;
      expect(block.poster).toMatch(/-20260916\.webp$/);
      expect(block.animation).toBeUndefined();
      posters.add(block.poster);
    }
    for (const poster of posters) {
      const image = await request.get(poster);
      expect(image.status(), poster).toBe(200);
      expect(image.headers()["content-type"]).toContain("image/webp");
    }
    await page.goto(`/tutorial/${locale}/static?step=references`);
    const screenshot = page.locator(".tutorial-step:not([hidden]) img");
    await expect(screenshot).toHaveAttribute("src", /create-references-20260916\.webp/);
    await expect(screenshot).toBeVisible();
    await expect.poll(() => screenshot.evaluate((image: HTMLImageElement) => image.naturalWidth)).toBe(804);
  }
});
