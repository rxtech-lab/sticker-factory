import { expect, test } from "@playwright/test";

for (const width of [1440, 768, 390, 320]) {
  test(`homepage FAQ keeps its height at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto("/");
    const faq = page.locator("#faq");
    await faq.scrollIntoViewIfNeeded();
    const before = await faq.boundingBox();
    for (const summary of await faq.locator("summary").all()) {
      await summary.click();
    }
    await expect(faq.locator("details[open]")).toHaveCount(6);
    const after = await faq.boundingBox();
    expect(after?.height).toBe(before?.height);
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width);
    await faq.locator("summary").first().focus();
    await page.keyboard.press("Enter");
    await expect(faq.locator("details").first()).not.toHaveAttribute("open");
    expect((await faq.boundingBox())?.height).toBe(before?.height);
  });
}

test("homepage respects reduced motion", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  await expect(page.locator(".scroll-wiggle")).toHaveCSS("animation-name", "none");
  await expect(page.locator(".scroll-reveal").first()).toHaveCSS("opacity", "1");
});
