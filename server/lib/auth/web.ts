import { createRxLabAuth } from "@rxtech-lab/authjs-rxlab";

export const isWebAuthConfigured = Boolean(
  process.env.AUTH_ISSUER
  && process.env.AUTH_CLIENT_ID
  && process.env.AUTH_CLIENT_SECRET
  && process.env.AUTH_SECRET,
);

// Placeholder values keep static builds and local UI previews working. OAuth calls are
// explicitly disabled in the UI until all confidential-client settings are present.
const rxLabAuth = createRxLabAuth({
  issuer: process.env.AUTH_ISSUER ?? "https://auth.rxlab.app",
  clientId: process.env.AUTH_CLIENT_ID ?? "sticker-factory-web-unconfigured",
  clientSecret: process.env.AUTH_CLIENT_SECRET ?? "unconfigured",
  signInPage: "/login",
  scope: "openid email profile",
  trustHost: true,
});

export const { handlers, auth, signIn, signOut, proxy } = rxLabAuth;
