import { readFileSync } from "node:fs";
import path from "node:path";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { ApiError } from "@/lib/http/errors";
import { APP_STORE_ID } from "@/lib/sharing";
import type { BillingEnvironment } from "./config";

// Public Apple trust anchor, downloaded from Apple's PKI. Never trust an x5c
// root supplied by the caller. Keep verifier instances for Apple's bounded key cache.
const verifiers = new Map<string, SignedDataVerifier>();

function verifier(environment: Environment, bundleId: string, appAppleId: number): SignedDataVerifier {
  const key = `${environment}:${bundleId}:${appAppleId}`;
  let value = verifiers.get(key);
  if (!value) {
    const root = readFileSync(path.join(process.cwd(), "lib/subscription/certificates/AppleRootCA-G3.cer"));
    value = new SignedDataVerifier([root], true, environment, bundleId, appAppleId);
    verifiers.set(key, value);
  }
  return value;
}

export async function verifyAppBillingEnvironment(proof: string, clientId: string): Promise<BillingEnvironment> {
  if (proof.length > 16_384 || proof.split(".").length !== 3) throw invalidProof();
  const bundleId = process.env.APPLE_BUNDLE_ID?.trim() || "app.rxlab.stickerfactory";
  const appAppleId = Number(process.env.APPLE_APP_ID?.trim() || APP_STORE_ID);
  if (!Number.isSafeInteger(appAppleId) || appAppleId <= 0) {
    throw new ApiError(503, "SUBSCRIPTION_NOT_CONFIGURED", "The App Store app ID is invalid");
  }
  const bundleIds = clientId === process.env.APP_CLIP_OAUTH_CLIENT_ID?.trim()
    ? [bundleId, `${bundleId}.Clip`] : [bundleId];
  // Try only real Apple environments. The library intentionally skips signature
  // verification for Xcode, so that environment must never be accepted here.
  for (const expectedBundle of bundleIds) {
    for (const [appleEnvironment, billingEnvironment] of [
      [Environment.SANDBOX, "sandbox"], [Environment.PRODUCTION, "production"],
    ] as const) {
      try {
        await verifier(appleEnvironment, expectedBundle, appAppleId).verifyAndDecodeAppTransaction(proof);
        return billingEnvironment;
      } catch (error) {
        if (error instanceof VerificationException && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
          throw new ApiError(503, "BILLING_VERIFICATION_UNAVAILABLE", "Apple verification is unavailable. Please try again.");
        }
        if (!(error instanceof VerificationException)) throw error;
        if (error.status !== VerificationStatus.INVALID_ENVIRONMENT && error.status !== VerificationStatus.INVALID_APP_IDENTIFIER) {
          throw invalidProof();
        }
      }
    }
  }
  throw invalidProof();
}

function invalidProof(): ApiError {
  return new ApiError(403, "INVALID_BILLING_ENVIRONMENT", "The app's billing environment could not be verified.");
}
