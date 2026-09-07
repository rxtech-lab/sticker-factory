import { expect, test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("API verifies bearer signatures, expiry, issuer and OAuth client", async ({ request }) => {
  await expectError(await request.get("/api/v1/stickers"), 401, "MISSING_ACCESS_TOKEN");
  await expectError(await request.get("/api/v1/stickers", { headers: { authorization: "Bearer invalid" } }), 401, "INVALID_ACCESS_TOKEN");
  for (const query of ["?expired=true", "?issuer=https://wrong.invalid"]) {
    await expectError(await request.get("/api/v1/stickers", { headers: await headers(request, query) }), 401, "INVALID_ACCESS_TOKEN");
  }
  await expectError(await request.get("/api/v1/stickers", { headers: await headers(request, "?client=forbidden") }), 403, "OAUTH_CLIENT_NOT_ALLOWED");
  const response = await request.get("/api/v1/stickers", { headers: await headers(request, "?sub=fresh-reader") });
  expect(response.status()).toBe(200);
  expect((await response.json()).data).toEqual([]);
});
