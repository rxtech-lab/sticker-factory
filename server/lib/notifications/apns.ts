import http2 from "node:http2";
import { importPKCS8, SignJWT } from "jose";

/**
 * The Apple Push Notification service, over the one transport it accepts.
 *
 * APNs is HTTP/2-only and will not talk to `fetch` (undici negotiates h2 for nobody), so this uses
 * `node:http2` directly. That is the whole reason this file exists rather than a four-line wrapper.
 *
 * Everything is best-effort by construction: `sendPushes` reports per-token outcomes and throws
 * only if the connection itself cannot be made. A banner is a courtesy, and no generation should
 * ever fail because Apple was slow.
 */

const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;

export type ApnsEnvironment = keyof typeof APNS_HOSTS;

/**
 * Token-based (`.p8`) authentication. Certificates are deliberately unsupported: one key signs for
 * every topic in the team and never expires, which is the only shape that survives being an
 * environment variable.
 */
export interface ApnsConfig {
  keyId: string;
  teamId: string;
  /** PKCS#8 PEM. */
  privateKey: string;
  /** The app's bundle identifier, which APNs calls the topic. */
  bundleId: string;
  /** Overrides the per-token environment, for a deployment that only ever talks to one host. */
  environment?: ApnsEnvironment;
}

export interface ApnsPush {
  token: string;
  environment: ApnsEnvironment;
  payload: Record<string, unknown>;
  /** APNs replaces an undelivered notification carrying the same id. Max 64 bytes. */
  collapseId?: string;
  pushType?: "alert" | "liveactivity";
  priority?: "5" | "10";
}

export interface ApnsResult {
  token: string;
  ok: boolean;
  status: number;
  /** Apple's machine-readable failure, e.g. `BadDeviceToken`, `Unregistered`, `TooManyRequests`. */
  reason?: string;
  /** True when this token will never work again and should stop being tried. */
  permanentlyGone: boolean;
}

/**
 * Apple's provider tokens are valid for an hour and re-issuing one on every push earns a
 * `TooManyProviderTokenUpdates`. Refresh comfortably inside the window instead.
 */
const PROVIDER_TOKEN_TTL_MS = 45 * 60 * 1000;
const CONNECT_TIMEOUT_MS = 10_000;
const REQUEST_TIMEOUT_MS = 10_000;

/**
 * Failures that mean the row is dead, not that the send went badly.
 *
 * `Unregistered` (410) is the app being deleted. `BadDeviceToken` is a token from the other
 * environment, or a garbled one — either way, re-sending it tomorrow fails the same way.
 */
const GONE_REASONS = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);

let cachedProviderToken: { key: string; token: string; expiresAt: number } | undefined;

/**
 * Accepts the key however an environment variable managed to carry it: a real PEM, a PEM whose
 * newlines were escaped on the way in, or the whole file base64-encoded.
 */
function normalizePrivateKey(raw: string): string {
  const value = raw.includes("BEGIN ")
    ? raw.replace(/\\n/g, "\n")
    : Buffer.from(raw, "base64").toString("utf8");
  return `${value.trim()}\n`;
}

/**
 * The APNs configuration, or `undefined` when the deployment has none.
 *
 * Missing credentials are a normal state — local development, tests, and any environment that has
 * not been given a `.p8` yet — so this returns nothing rather than throwing, and the notification
 * layer above treats that as "no banners today".
 */
export function getApnsConfig(): ApnsConfig | undefined {
  const keyId = process.env.APNS_KEY_ID?.trim();
  const teamId = process.env.APNS_TEAM_ID?.trim();
  const privateKey = process.env.APNS_PRIVATE_KEY?.trim();
  const bundleId = process.env.APNS_BUNDLE_ID?.trim();
  if (!keyId || !teamId || !privateKey || !bundleId) return undefined;
  return {
    keyId,
    teamId,
    privateKey: normalizePrivateKey(privateKey),
    bundleId,
    environment: parseEnvironmentOverride(process.env.APNS_ENVIRONMENT),
  };
}

/**
 * Reads the optional host override, `undefined` meaning "let each device's registration decide".
 *
 * The aliases exist because Apple itself calls the same host "sandbox" in one place and
 * "development" in another (the entitlement says `development`), and the sibling relay service
 * accepts both — a deployment copying its configuration across should not silently get per-device
 * behaviour because it wrote the other word.
 */
function parseEnvironmentOverride(raw: string | undefined): ApnsEnvironment | undefined {
  switch (raw?.trim().toLowerCase()) {
    case "sandbox":
    case "development":
    case "dev":
      return "sandbox";
    case "production":
    case "prod":
    case "release":
      return "production";
    default:
      return undefined;
  }
}

export async function providerToken(config: ApnsConfig): Promise<string> {
  const cacheKey = `${config.teamId}:${config.keyId}`;
  if (cachedProviderToken?.key === cacheKey && cachedProviderToken.expiresAt > Date.now()) {
    return cachedProviderToken.token;
  }
  const key = await importPKCS8(config.privateKey, "ES256");
  const token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyId })
    .setIssuer(config.teamId)
    .setIssuedAt()
    .sign(key);
  cachedProviderToken = { key: cacheKey, token, expiresAt: Date.now() + PROVIDER_TOKEN_TTL_MS };
  return token;
}

/** Only for tests, which sign with a throwaway key and must not see the previous one. */
export function resetProviderTokenCache(): void {
  cachedProviderToken = undefined;
}

function connect(origin: string): Promise<http2.ClientHttp2Session> {
  return new Promise((resolve, reject) => {
    const session = http2.connect(origin);
    const timer = setTimeout(() => {
      session.destroy();
      reject(new Error(`APNs connection to ${origin} timed out`));
    }, CONNECT_TIMEOUT_MS);
    const fail = (error: Error) => {
      clearTimeout(timer);
      session.destroy();
      reject(error);
    };
    session.once("error", fail);
    session.once("connect", () => {
      clearTimeout(timer);
      session.off("error", fail);
      resolve(session);
    });
  });
}

function post(
  session: http2.ClientHttp2Session,
  path: string,
  headers: http2.OutgoingHttpHeaders,
  body: string,
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const stream = session.request({ ...headers, ":method": "POST", ":path": path });
    const chunks: Buffer[] = [];
    let status = 0;
    stream.setTimeout(REQUEST_TIMEOUT_MS, () => {
      stream.close(http2.constants.NGHTTP2_CANCEL);
      reject(new Error("APNs request timed out"));
    });
    stream.on("response", (responseHeaders) => {
      status = Number(responseHeaders[":status"] ?? 0);
    });
    stream.on("data", (chunk: Buffer) => chunks.push(Buffer.from(chunk)));
    stream.on("error", reject);
    stream.on("end", () => resolve({ status, body: Buffer.concat(chunks).toString("utf8") }));
    stream.end(body);
  });
}

function readReason(body: string): string | undefined {
  if (!body) return undefined;
  try {
    const parsed: unknown = JSON.parse(body);
    const reason = (parsed as { reason?: unknown }).reason;
    return typeof reason === "string" ? reason : undefined;
  } catch {
    return body.slice(0, 200);
  }
}

/**
 * Delivers every push, one HTTP/2 connection per environment.
 *
 * Pushes to the same host share a connection because that is what HTTP/2 is for, and the
 * connection is closed at the end: a serverless instance is frozen between invocations, and a
 * socket held across that freeze is one APNs has already dropped.
 */
export async function sendPushes(pushes: ApnsPush[], config: ApnsConfig): Promise<ApnsResult[]> {
  if (pushes.length === 0) return [];
  const authorization = `bearer ${await providerToken(config)}`;
  const byEnvironment = new Map<ApnsEnvironment, ApnsPush[]>();
  for (const push of pushes) {
    const environment = config.environment ?? push.environment;
    const group = byEnvironment.get(environment);
    if (group) group.push(push); else byEnvironment.set(environment, [push]);
  }

  const results: ApnsResult[] = [];
  for (const [environment, group] of byEnvironment) {
    let session: http2.ClientHttp2Session;
    try {
      session = await connect(APNS_HOSTS[environment]);
    } catch (error) {
      // A host that cannot be reached says nothing about the tokens pointed at it, so none of them
      // are marked gone — this turn simply goes unannounced.
      const message = error instanceof Error ? error.message : String(error);
      results.push(...group.map((push) => ({
        token: push.token,
        ok: false,
        status: 0,
        reason: message,
        permanentlyGone: false,
      })));
      continue;
    }
    try {
      results.push(...await Promise.all(group.map(async (push): Promise<ApnsResult> => {
        try {
          const { status, body } = await post(session, `/3/device/${push.token}`, {
            authorization,
            "apns-topic": push.pushType === "liveactivity" ? `${config.bundleId}.push-type.liveactivity` : config.bundleId,
            "apns-push-type": push.pushType ?? "alert",
            // The turn finished now; a banner that arrives an hour later is a lie.
            "apns-priority": push.priority ?? "10",
            "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
            ...(push.collapseId ? { "apns-collapse-id": push.collapseId.slice(0, 64) } : {}),
            "content-type": "application/json",
          }, JSON.stringify(push.payload));
          const reason = status === 200 ? undefined : readReason(body);
          return {
            token: push.token,
            ok: status === 200,
            status,
            reason,
            permanentlyGone: status === 410 || (reason !== undefined && GONE_REASONS.has(reason)),
          };
        } catch (error) {
          return {
            token: push.token,
            ok: false,
            status: 0,
            reason: error instanceof Error ? error.message : String(error),
            permanentlyGone: false,
          };
        }
      })));
    } finally {
      session.close();
    }
  }
  return results;
}
