import { createServer } from "node:http";
import { exportJWK, generateKeyPair, SignJWT } from "jose";

// Test-only issuer: production token verification still fetches JWKS and verifies RS256.
const issuer = "http://127.0.0.1:3106";
const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk = { ...await exportJWK(publicKey), kid: "e2e", alg: "RS256", use: "sig" };
createServer(async (request, response) => {
  const url = new URL(request.url!, issuer);
  response.setHeader("Content-Type", "application/json");
  if (url.pathname === "/.well-known/jwks.json") {
    response.end(JSON.stringify({ keys: [jwk] }));
  } else if (url.pathname === "/token") {
    const token = await new SignJWT({ client_id: url.searchParams.get("client") ?? "e2e-client" })
      .setProtectedHeader({ alg: "RS256", kid: "e2e" })
      .setIssuer(url.searchParams.get("issuer") ?? issuer)
      .setSubject(url.searchParams.get("sub") ?? "playwright-user")
      .setExpirationTime(url.searchParams.get("expired") ? "0s" : "1h")
      .sign(privateKey);
    response.end(JSON.stringify({ token }));
  } else {
    response.statusCode = 404;
    response.end("{}");
  }
}).listen(3106, "127.0.0.1");
