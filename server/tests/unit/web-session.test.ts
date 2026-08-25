import { describe, expect, it } from "vitest";
import { isHealthyWebSession, RX_LAB_REFRESH_TOKEN_ERROR_VALUE } from "@/lib/auth/session-health";

describe("web session health", () => {
  it("rejects a long-lived Auth.js cookie after refresh-token revocation", () => {
    expect(isHealthyWebSession({
      user: { id: "user-1", name: "User" },
      expires: new Date(Date.now() + 86_400_000).toISOString(),
      error: RX_LAB_REFRESH_TOKEN_ERROR_VALUE,
    })).toBe(false);
  });

  it("accepts a healthy identified session", () => {
    expect(isHealthyWebSession({
      user: { id: "user-1", name: "User" },
      expires: new Date(Date.now() + 86_400_000).toISOString(),
    })).toBe(true);
  });
});
