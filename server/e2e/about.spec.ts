import { expect, test } from "@playwright/test";
import { aboutPurpose } from "../lib/about";

test.describe("about", () => {
  test("shows why the app was built and its authors", async ({ page }) => {
    await page.goto("/about");

    await expect(page.getByRole("heading", { name: "Why we built it." })).toBeVisible();
    await expect(page.getByText(aboutPurpose)).toBeVisible();
    await expect(page.getByText(`Created by Bard and Zoey · © ${new Date().getUTCFullYear()}`)).toBeVisible();
  });
});
