import { ApiError } from "@/lib/http/errors";

/**
 * Where the shared RxSubscription service lives, and the secret key we reach it
 * with.
 *
 * The key is a *secret* key held only here. The iOS app carries a publishable
 * one, which can read a user's own entitlements and start a purchase but
 * cannot move a balance — reserving and settling credits has to happen
 * somewhere a user cannot reach, and this is that place.
 */
export interface SubscriptionConfig {
  baseURL: string;
  apiKey: string;
  environment: BillingEnvironment | null;
}

export type BillingEnvironment = "xcode" | "sandbox" | "production";

/**
 * Selects a verified request environment or a persisted job environment.
 * Null uses only the explicit legacy/deployment configuration, never a request.
 * Only an entirely unconfigured local development/test server may skip billing.
 */
export function subscriptionConfig(verifiedEnvironment: BillingEnvironment | null = null): SubscriptionConfig | null {
  const baseURL = process.env.RX_SUBSCRIPTION_URL?.trim();
  const environment = verifiedEnvironment ?? process.env.RX_SUBSCRIPTION_ENVIRONMENT?.trim();
  const legacyKey = process.env.RX_SUBSCRIPTION_API_KEY?.trim();
  const sandboxKey = process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY?.trim();
  const productionKey = process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY?.trim();
  const deployed = process.env.NODE_ENV === "production" ||
    Boolean(process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development");
  if (!deployed && !baseURL && !environment && !legacyKey && !sandboxKey && !productionKey) return null;

  // Never infer sandbox from Vercel's "preview" or production from its
  // "production": TestFlight also talks to the production deployment.
  if (environment && environment !== "sandbox" && environment !== "production" && environment !== "xcode") {
    throw configurationError("RX_SUBSCRIPTION_ENVIRONMENT must be sandbox or production");
  }
  const namedKey = environment === "sandbox" ? sandboxKey :
    environment === "production" ? productionKey : undefined;
  const apiKey = environment ? namedKey || (legacyKey?.startsWith(`rxs_${environment}_`) ? legacyKey : undefined) : legacyKey;
  if (!baseURL || !apiKey) {
    throw configurationError("Configure the billing URL and secret key for the selected environment");
  }
  if (environment && !apiKey.startsWith(`rxs_${environment}_`)) {
    throw configurationError("The billing secret key does not match the selected environment");
  }
  const keyEnvironment = (["xcode", "sandbox", "production"] as const).find(value => apiKey.startsWith(`rxs_${value}_`)) ?? null;
  return { baseURL: baseURL.replace(/\/+$/, ""), apiKey, environment: keyEnvironment };
}

function configurationError(message: string): ApiError {
  return new ApiError(503, "SUBSCRIPTION_NOT_CONFIGURED", message);
}

/** False only for unconfigured local development/tests; invalid deployments throw. */
export function subscriptionEnabled(): boolean {
  // Request proof is resolved asynchronously by the billing client. Split keys
  // enable enforcement even though no request has selected one yet.
  if (process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY?.trim() || process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY?.trim()) return true;
  return subscriptionConfig() !== null;
}
