import { expect, test } from "@playwright/test";

test.describe.serial("authenticated web library", () => {
  let stickerId: string;

  test.beforeAll(async ({ request }) => {
    const response = await request.post("/api/e2e/seed", { headers: { "x-e2e-key": "local-playwright-seed" } });
    expect(response.ok()).toBeTruthy();
    stickerId = (await response.json()).staticStickerId;
  });

  test("mocked healthy session bypasses sign-in while the login guard redirects", async ({ page }) => {
    await page.goto("/login");
    await expect(page).toHaveURL(/\/library$/);
    await expect(page.getByRole("heading", { name: "Your sticker library" })).toBeVisible();
  });

  test("filters static and animated projects and renders private previews", async ({ page }) => {
    await page.goto("/library");
    await expect(page.getByRole("link", { name: /Playwright Cloud/ })).toBeVisible();
    const preview = page.getByAltText("Playwright Cloud preview");
    await expect(preview).toHaveAttribute("src", /downloads\.invalid/);
    await page.getByRole("link", { name: "Animated", exact: true }).click();
    await expect(page.getByRole("link", { name: /Playwright Bounce/ })).toBeVisible();
    await expect(page.getByRole("link", { name: /Playwright Cloud/ })).toHaveCount(0);
  });

  test("shows parent-based revision comparison, downloads, and read-only chat", async ({ page }) => {
    await page.goto(`/library/${stickerId}`);
    await expect(page.getByRole("navigation", { name: "Choose revision to compare" })).toBeVisible();
    await expect(page.getByRole("region", { name: "Revision comparison" })).toContainText("Selected");
    await expect(page.getByRole("heading", { name: "Project chat" })).toBeVisible();
    await expect(page.getByText("Make the cloud coral pink")).toBeVisible();
    await expect(page.getByRole("link", { name: "PNG export" })).toHaveAttribute("href", /\/download\//);
    await expect(page.getByRole("link", { name: "System sticker" })).toHaveAttribute("href", /\/download\//);
    await expect(page.getByRole("button", { name: "Delete project and media" })).toBeVisible();
  });

  test("loops animated detail previews and opens a full-screen player", async ({ page }) => {
    await page.goto("/library");
    const animatedProject = page.getByRole("link", { name: /Playwright Bounce/ });
    const href = await animatedProject.getAttribute("href");
    expect(href).toBeTruthy();
    await page.goto(href!);

    const openPlayer = page.getByRole("button", { name: "Open Playwright Bounce animated revision full screen" }).first();
    await expect(openPlayer.locator(".sticker-scene, video[autoplay][loop]")).toBeVisible();
    await openPlayer.click();
    const player = page.getByRole("dialog", { name: "Playwright Bounce animated revision full-screen player" });
    await expect(player).toBeVisible();
    await expect(player.locator(".sticker-scene, video[autoplay][loop]")).toBeVisible();
    await page.getByRole("button", { name: "Close full-screen player" }).click();
    await expect(player).toHaveCount(0);
  });

  test("deletion action removes the project from the visible library", async ({ page }) => {
    await page.goto(`/library/${stickerId}`);
    await page.getByRole("button", { name: "Delete project and media" }).click();
    await expect(page).toHaveURL(/\/library$/);
    await expect(page.getByRole("link", { name: /Playwright Cloud/ })).toHaveCount(0);
  });
});
