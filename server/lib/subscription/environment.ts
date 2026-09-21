import { AsyncLocalStorage } from "node:async_hooks";
import { and, eq, sql } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { firstRow, type Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { verifyAppBillingEnvironment, verifyTransactionBillingEnvironment } from "./verify-app-transaction";
import type { BillingEnvironment } from "./config";

export const APP_TRANSACTION_HEADER = "x-storekit-app-transaction";
/** A signed purchase, sent only when the device could not produce an `AppTransaction`. */
export const TRANSACTION_HEADER = "x-storekit-transaction";

type VerifiedEnvironment = "sandbox" | "production";

interface BillingRequest {
  resolve: () => Promise<BillingEnvironment | null>;
  result?: Promise<BillingEnvironment | null>;
}
const requests = new AsyncLocalStorage<BillingRequest>();

/** Proof is checked only when the handler reaches a billing operation. Reads,
 * cancellations and downloads still work when StoreKit is temporarily unavailable.
 * AsyncLocalStorage isolates concurrent sandbox and production requests.
 *
 * StoreKit fails outright for some Apple IDs, so a mobile request without proof is not refused:
 * it uses the environment Apple last proved for this user, and production when there is none.
 * Sandbox credits cost nothing, so sandbox is only ever reached through an Apple signature —
 * this request's, or an earlier one's. A proof that is presented and does not verify still fails.
 */
export function withBillingRequest<T>(request: Request, principal: ApiPrincipal, action: () => T, db?: Database): T {
  return requests.run({ resolve: async () => {
    const appTransaction = request.headers.get(APP_TRANSACTION_HEADER);
    const transaction = appTransaction ? null : request.headers.get(TRANSACTION_HEADER);
    if (appTransaction || transaction) {
      const verified = appTransaction
        ? await verifyAppBillingEnvironment(appTransaction)
        : await verifyTransactionBillingEnvironment(transaction!);
      if (verified !== "xcode") await rememberEnvironment(db, principal.sub, verified);
      return verified;
    }
    const usesEnvironmentKeys = Boolean(process.env.RX_SUBSCRIPTION_SANDBOX_API_KEY?.trim() ||
      process.env.RX_SUBSCRIPTION_PRODUCTION_API_KEY?.trim());
    if (!usesEnvironmentKeys) return null; // Legacy/local single-key deployments.
    // Only the authenticated web OAuth client can use production without StoreKit.
    // User-supplied platform or environment headers never select a billing key.
    const iosClientId = process.env.IOS_OAUTH_CLIENT_ID?.trim();
    const appClipClientId = process.env.APP_CLIP_OAUTH_CLIENT_ID?.trim();
    if (principal.clientId === process.env.AUTH_CLIENT_ID?.trim() &&
      principal.clientId !== iosClientId &&
      principal.clientId !== appClipClientId) return "production";
    if (principal.clientId === iosClientId || principal.clientId === appClipClientId) {
      return await lastVerifiedEnvironment(db, principal.sub) ?? "production";
    }
    throw new ApiError(403, "BILLING_ENVIRONMENT_REQUIRED",
      "Update the app to verify its billing environment, then try again.");
  } }, action);
}

export function requestBillingEnvironment(): Promise<BillingEnvironment | null> {
  const context = requests.getStore();
  if (!context) return Promise.resolve(null);
  return context.result ??= context.resolve();
}

/** Written only when it changes, so a user's ordinary requests cost one statement that matches nothing. */
async function rememberEnvironment(db: Database | undefined, userId: string, environment: VerifiedEnvironment): Promise<void> {
  if (!db) return;
  try {
    await db.update(users)
      .set({ lastBillingEnvironment: environment })
      .where(and(eq(users.id, userId), sql`${users.lastBillingEnvironment} IS DISTINCT FROM ${environment}`));
  } catch (error) {
    // Apple already verified this request. Failing to remember that must not refuse it.
    console.error("Could not remember a user's verified billing environment", { userId, error });
  }
}

/** Null for a user Apple has never vouched for, and for a read that arrives before their row exists. */
async function lastVerifiedEnvironment(db: Database | undefined, userId: string): Promise<VerifiedEnvironment | null> {
  if (!db) return null;
  const row = await db.select({ environment: users.lastBillingEnvironment })
    .from(users).where(eq(users.id, userId)).then(firstRow);
  return row?.environment ?? null;
}
