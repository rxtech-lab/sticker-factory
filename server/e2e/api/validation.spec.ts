import { test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("API rejects malformed JSON, invalid payloads, missing keys and invalid pagination", async ({ request }) => {
  const auth = await headers(request);
  await expectError(await request.post("/api/v1/packs", { headers: auth, data: { title: "Valid" } }), 400, "IDEMPOTENCY_KEY_REQUIRED");
  await expectError(await request.post("/api/v1/packs", { headers: auth, data: { title: "" } }), 400, "VALIDATION_ERROR");
  await expectError(await request.post("/api/v1/packs", { headers: { ...auth, "content-type": "application/json" }, data: Buffer.from("{") }), 400, "INVALID_JSON");
  await expectError(await request.post("/api/v1/packs", { headers: { ...auth, "content-type": "text/plain" }, data: "hello" }), 415, "UNSUPPORTED_MEDIA_TYPE");
  await expectError(await request.get("/api/v1/stickers?limit=0", { headers: auth }), 400, "INVALID_QUERY");
});
