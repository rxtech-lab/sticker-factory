import { generateKeyPair, SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { verifyBearerToken } from "@/lib/auth/bearer";

describe("RxLab bearer verification", () => {
  it("verifies issuer, RS256, expiry, subject, and allowed client_id", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256");
    const issuer = "https://auth.rxlab.app";
    const token = await new SignJWT({ client_id: "ios-client", email: "user@example.test", scope: "openid profile" })
      .setProtectedHeader({ alg: "RS256", kid: "test" })
      .setIssuer(issuer)
      .setSubject("user-123")
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey);

    await expect(verifyBearerToken(token, {
      issuer,
      allowedClientIds: new Set(["ios-client"]),
      key: publicKey,
    })).resolves.toMatchObject({ sub: "user-123", clientId: "ios-client", email: "user@example.test" });

    await expect(verifyBearerToken(token, {
      issuer,
      allowedClientIds: new Set(["other-client"]),
      key: publicKey,
    })).rejects.toMatchObject({ code: "OAUTH_CLIENT_NOT_ALLOWED", status: 403 });
  });

  it("rejects expired tokens and wrong issuers", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256");
    const token = await new SignJWT({ client_id: "ios-client" })
      .setProtectedHeader({ alg: "RS256" })
      .setIssuer("https://wrong.example")
      .setSubject("user-123")
      .setExpirationTime(1)
      .sign(privateKey);
    await expect(verifyBearerToken(token, {
      issuer: "https://auth.rxlab.app",
      allowedClientIds: new Set(["ios-client"]),
      key: publicKey,
    })).rejects.toMatchObject({ code: "INVALID_ACCESS_TOKEN", status: 401 });
  });
});
