import { expect, test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("device API accepts repeated registration and unregistration", async ({ request }) => {
  const auth = await headers(request, `?sub=device-owner-${crypto.randomUUID()}`);
  const token = crypto.randomUUID().replaceAll("-", "").repeat(2);
  await expectError(await request.post("/api/v1/devices", { headers: auth, data: { token: "invalid" } }), 400, "VALIDATION_ERROR");
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await request.post("/api/v1/devices", { headers: auth, data: { token, environment: "sandbox" } });
    expect(response.status()).toBe(200);
    expect((await response.json()).token).toBe(token);
  }
  for (let attempt = 0; attempt < 2; attempt++) {
    const response = await request.delete(`/api/v1/devices/${token}`, { headers: auth });
    expect(response.status()).toBe(200);
    expect(await response.json()).toEqual({ token, unregistered: true });
  }
});
