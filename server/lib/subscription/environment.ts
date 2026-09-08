import { AsyncLocalStorage } from "node:async_hooks";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { ApiError } from "@/lib/http/errors";
import { verifyAppBillingEnvironment } from "./verify-app-transaction";
import type { BillingEnvironment } from "./config";

export const APP_TRANSACTION_HEADER = "x-storekit-app-transaction";

interface BillingRequest {
  resolve: () => Promise<BillingEnvironment | null>;
  result?: Promise<BillingEnvironment | null>;
}
const requests = new AsyncLocalStorage<BillingRequest>();

/** Proof is checked only when the handler reaches a billing operation. Reads,
 * cancellations and downloads still work when StoreKit is temporarily unavailable.
 * AsyncLocalStorage isolates concurrent sandbox and production requests.
 */
export function withBillingRequest<T>(request: Request, principal: ApiPrincipal, action: () => T): T {
  return requests.run({ resolve: async () => {
    const proof = request.headers.get(APP_TRANSACTION_HEADER);
    if (proof) return verifyAppBillingEnvironment(proof, principal.clientId);
    const usesEnvironmentKeys = Boolean(process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY?.trim() ||
      process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY?.trim());
    if (!usesEnvironmentKeys) return null; // Legacy/local single-key deployments.
    // Only the authenticated web OAuth client can use production without StoreKit.
    // User-supplied platform or environment headers never select a billing key.
    if (principal.clientId === process.env.AUTH_CLIENT_ID?.trim() &&
      principal.clientId !== process.env.IOS_OAUTH_CLIENT_ID?.trim() &&
      principal.clientId !== process.env.APP_CLIP_OAUTH_CLIENT_ID?.trim()) return "production";
    throw new ApiError(403, "BILLING_ENVIRONMENT_REQUIRED",
      "Update the app to verify its billing environment, then try again.");
  } }, action);
}

export function requestBillingEnvironment(): Promise<BillingEnvironment | null> {
  const context = requests.getStore();
  if (!context) return Promise.resolve(null);
  return context.result ??= context.resolve();
}
