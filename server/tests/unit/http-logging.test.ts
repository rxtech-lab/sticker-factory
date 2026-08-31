import { describe, expect, it } from "vitest";
import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import { apiFailureDetails, apiRequestMetadata, safeLogValue } from "@/lib/http/logging";

describe("API diagnostics", () => {
  it("logs useful request metadata without logging credentials or parameter values", () => {
    const request = new Request("https://example.test/api/v1/packs?q=private-search&sort=recent", {
      method: "POST",
      headers: {
        authorization: "Bearer private-token",
        "content-type": "application/json; charset=utf-8",
        "content-length": "42",
        "idempotency-key": "private-idempotency-key",
        "x-sticker-contract": "2",
      },
    });

    const metadata = apiRequestMetadata(request, {
      sub: "private-user-id",
      clientId: "ios-client",
      scopes: ["openid", "profile"],
    });

    expect(metadata).toMatchObject({
      queryKeys: ["q", "sort"],
      contentType: "application/json",
      contentLength: "42",
      idempotencyKey: "present",
      stickerContract: "2",
      oauthClient: "ios-client",
      scopeCount: 2,
    });
    expect(JSON.stringify(metadata)).not.toContain("private-token");
    expect(JSON.stringify(metadata)).not.toContain("private-idempotency-key");
    expect(JSON.stringify(metadata)).not.toContain("private-search");
    expect(JSON.stringify(metadata)).not.toContain("private-user-id");
  });

  it("includes API error codes and details", () => {
    expect(apiFailureDetails(new ApiError(400, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key is required")))
      .toMatchObject({
        type: "ApiError",
        code: "IDEMPOTENCY_KEY_REQUIRED",
        message: "Idempotency-Key is required",
      });
  });

  it("includes exact Zod issue paths without retaining the rejected payload", () => {
    const schema = z.object({ byteSize: z.number().positive(), token: z.string() }).strict();
    const result = schema.safeParse({ byteSize: -1, token: "private-token", unexpected: "private-value" });
    expect(result.success).toBe(false);
    if (result.success) return;

    const details = apiFailureDetails(result.error);
    expect(details).toMatchObject({
      code: "VALIDATION_ERROR",
      details: { issues: expect.arrayContaining([expect.objectContaining({ path: ["byteSize"] })]) },
    });
    expect(JSON.stringify(details)).not.toContain("private-token");
    expect(JSON.stringify(details)).not.toContain("private-value");
  });

  it("redacts sensitive nested fields", () => {
    expect(safeLogValue({ authorization: "Bearer secret", nested: { password: "secret", token: "secret", kind: "system" } }))
      .toEqual({
        authorization: "[redacted]",
        nested: { password: "[redacted]", token: "[redacted]", kind: "system" },
      });
  });
});
