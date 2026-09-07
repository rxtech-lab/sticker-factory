import { expect, test } from "@playwright/test";

test("quick share page and Apple association are publicly reachable", async ({ page, request }) => {
  const response = await request.get("/.well-known/apple-app-site-association");
  expect(response.status()).toBe(200);
  expect((await response.json()).appclips.apps).toContain("T7GYB573Y6.app.rxlab.stickerfactory.Clip");
  await page.goto("/share/ios");
  await expect(page.getByRole("heading", { name: "Your idea. Your sticker." })).toBeVisible();
  await expect(page.locator('meta[name="apple-itunes-app"]')).toHaveAttribute("content", /app-id=6805825708.*app-clip-bundle-id=app.rxlab.stickerfactory.Clip/);
  await expect(page.getByRole("link", { name: "Get Sticker Factory", exact: true })).toHaveAttribute("href", "https://apps.apple.com/app/id6805825708");
});

test("shared pack previews need no bearer token and install links point to the full app", async ({ page, request }) => {
  const seeded = await request.post("/api/e2e/seed", { headers: { "x-e2e-key": "local-playwright-seed" } });
  expect(seeded.status()).toBe(200);
  const { packSlug } = await seeded.json();
  const publicResponse = await request.get(`/api/v1/public/packs/${packSlug}`);
  expect(publicResponse.status()).toBe(200);
  const pack = await publicResponse.json();
  expect(pack.stickers.length).toBeGreaterThan(0);
  expect(pack.creator.isSelf).toBeUndefined();
  await page.goto(`/share/ios/packs/${packSlug}`);
  await expect(page.getByRole("heading", { name: pack.title, exact: true })).toBeVisible();
  await expect(page.getByRole("link", { name: "Install in Sticker Factory", exact: true })).toHaveAttribute("href", "https://apps.apple.com/app/id6805825708");
  await expect(page.locator(".sticker-preview img").first()).toBeVisible();
  expect((await request.get("/api/v1/public/packs/nonexistent-pack")).status()).toBe(404);
});
