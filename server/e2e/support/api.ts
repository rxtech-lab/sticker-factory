import { expect, type APIRequestContext, type APIResponse } from "@playwright/test";

export async function headers(request: APIRequestContext, query = "") {
  const response = await request.get(`http://127.0.0.1:3106/token${query}`);
  expect(response.ok()).toBeTruthy();
  return { authorization: `Bearer ${(await response.json()).token}` };
}
export async function expectError(response: APIResponse, status: number, code: string) {
  expect(response.status()).toBe(status);
  const body = await response.json();
  expect(body.error.code).toBe(code);
  expect(body.error.requestId).toBe(response.headers()["x-request-id"]);
  expect(response.headers()["cache-control"]).toContain("no-store");
}
