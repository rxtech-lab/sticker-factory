import { expect, test } from "@playwright/test";

/**
 * The Playwright user is always the *installer*: `getHealthyWebSession` mocks exactly one user
 * under E2E, and the seeded pack belongs to a second, unmocked creator.
 */
test.describe.serial("marketplace", () => {
  let packSlug: string;
  let creatorHandle: string;

  test.beforeAll(async ({ request }) => {
    const response = await request.post("/api/e2e/seed", { headers: { "x-e2e-key": "local-playwright-seed" } });
    expect(response.ok()).toBeTruthy();
    const seeded = await response.json();
    packSlug = seeded.packSlug;
    creatorHandle = seeded.creatorHandle;
    expect(packSlug).toBeTruthy();
    expect(creatorHandle).toBeTruthy();
  });

  test("browses packs and opens a pack detail with its creator and install count", async ({ page }) => {
    await page.goto("/marketplace");
    await expect(page.getByRole("heading", { name: "Sticker packs" })).toBeVisible();
    await page.getByRole("link", { name: /Playwright Pack/ }).click();

    await expect(page).toHaveURL(new RegExp(`/marketplace/${packSlug}$`));
    await expect(page.getByRole("heading", { name: "Playwright Pack" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Playwright Creator" })).toBeVisible();
    await expect(page.getByText("No installs yet")).toBeVisible();
    await expect(page.getByAltText("Playwright Loaf preview")).toBeVisible();
  });

  test("adds the pack, shows it in the library, then removes it", async ({ page }) => {
    await page.goto(`/marketplace/${packSlug}`);
    await page.getByRole("button", { name: "Add to library" }).click();

    await expect(page.getByRole("button", { name: "Remove from library" })).toBeVisible();
    await expect(page.getByText("1 install")).toBeVisible();

    await page.goto("/library");
    const strip = page.getByRole("navigation", { name: "Added sticker packs" });
    await expect(strip.getByRole("link", { name: /Playwright Pack/ })).toBeVisible();

    await page.goto(`/marketplace/${packSlug}`);
    await page.getByRole("button", { name: "Remove from library" }).click();
    await expect(page.getByRole("button", { name: "Add to library" })).toBeVisible();
    await expect(page.getByText("No installs yet")).toBeVisible();

    await page.goto("/library");
    await expect(page.getByRole("navigation", { name: "Added sticker packs" })).toHaveCount(0);
  });

  test("lists every pack by a creator from their byline", async ({ page }) => {
    await page.goto(`/marketplace/${packSlug}`);
    await page.getByRole("link", { name: "Playwright Creator" }).click();

    await expect(page).toHaveURL(new RegExp(`/marketplace/creators/${creatorHandle}$`));
    await expect(page.getByRole("heading", { name: "Playwright Creator" })).toBeVisible();
    await expect(page.getByText(`@${creatorHandle}`)).toBeVisible();
    await expect(page.getByRole("link", { name: /Playwright Pack/ })).toBeVisible();
  });

  test("keeps another creator's pack out of the signed-in user's own packs", async ({ page }) => {
    await page.goto("/marketplace?mine=true");
    await expect(page.getByRole("heading", { name: "Your sticker packs" })).toBeVisible();
    await expect(page.getByRole("link", { name: /Playwright Pack/ })).toHaveCount(0);
  });

  test("creates a pack from the user's own published stickers and publishes it", async ({ page }) => {
    await page.goto("/marketplace/new");
    await expect(page.getByRole("heading", { name: "Create a sticker pack" })).toBeVisible();

    await page.getByLabel("Name").fill("My Test Pack");
    await page.getByLabel("Description").fill("Made by Playwright.");
    // Only published stickers are offered — an unpublished one has no system rendition.
    await page.getByRole("checkbox").first().check();
    await page.getByRole("button", { name: "Create pack" }).click();

    await expect(page).toHaveURL(/\/marketplace\/my-test-pack-[0-9a-f]{8}\/edit$/);
    await expect(page.getByText("Editing · draft")).toBeVisible();
    await page.getByRole("button", { name: "Publish" }).click();

    await expect(page.getByRole("heading", { name: "My Test Pack" })).toBeVisible();
    // The creator sees an explanation instead of an install button — self-install would duplicate
    // every one of their own stickers.
    await expect(page.getByText("Your stickers are already in your library.")).toBeVisible();
    await expect(page.getByRole("button", { name: "Add to library" })).toHaveCount(0);

    await page.goto("/marketplace?mine=true");
    await expect(page.getByRole("link", { name: /My Test Pack/ })).toBeVisible();
  });
});
