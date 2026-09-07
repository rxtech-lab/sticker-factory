import { expect, test, type APIRequestContext } from "@playwright/test";
import sharp from "sharp";

async function shareCard(request: APIRequestContext, path: string, title: string) {
  // Fetch as a messaging crawler so metadata must be present in the initial HTML.
  const response = await request.get(path, { headers: { "user-agent": "facebookexternalhit/1.1" } });
  expect(response.status()).toBe(200);
  const html = await response.text();
  const meta = (name: string) => html.match(new RegExp(`<meta (?:property|name)="${name}" content="([^"]+)"`))?.[1];
  const imageURL = `https://sticker.rxlab.app${path}/opengraph-image`;
  expect(meta("og:title")).toBe(title);
  expect(meta("og:image")).toBe(imageURL);
  expect(meta("og:image:width")).toBe("1200");
  expect(meta("og:image:height")).toBe("630");
  expect(meta("og:image:type")).toBe("image/png");
  expect(meta("twitter:card")).toBe("summary_large_image");
  expect(meta("twitter:image")).toBe(imageURL);
  expect(meta("twitter:image:alt")).toBeTruthy();

  const image = await request.get(new URL(imageURL).pathname);
  expect(image.status()).toBe(200);
  expect(image.headers()["content-type"]).toContain("image/png");
  const bytes = await image.body();
  expect(await sharp(bytes).metadata()).toMatchObject({ format: "png", width: 1200, height: 630 });
  expect(bytes.length).toBeLessThan(5 * 1024 * 1024);
  await test.info().attach("share-card", { body: bytes, contentType: "image/png" });
  return bytes;
}

test("iOS quick share exposes a generated social card to crawlers", async ({ request }) => {
  await shareCard(request, "/share/ios", "Make a sticker");
});

test("marketplace sharing leads to the public iOS pack card even when artwork is unavailable", async ({ page, request }) => {
  const seeded = await request.post("/api/e2e/seed", { headers: { "x-e2e-key": "local-playwright-seed" } });
  expect(seeded.status()).toBe(200);
  const { packSlug } = await seeded.json();
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "share", {
      value: async (data: ShareData) => { document.documentElement.dataset.sharedUrl = data.url; },
    });
  });
  await page.goto(`/marketplace/${packSlug}`);
  await page.getByRole("button", { name: "Share pack", exact: true }).click();
  const path = `/share/ios/packs/${packSlug}`;
  await expect(page.locator("html")).toHaveAttribute("data-shared-url", `https://sticker.rxlab.app${path}`);
  // The E2E object store returns downloads.invalid URLs; real decoding is covered in unit tests.
  await shareCard(request, path, "Playwright Pack");
});

test("unavailable pack images return an uncached 404", async ({ request }) => {
  const response = await request.get("/share/ios/packs/nonexistent-pack/opengraph-image");
  expect(response.status()).toBe(404);
  expect(response.headers()["cache-control"]).toContain("no-store");
});
