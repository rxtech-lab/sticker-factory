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
}

/**
 * Reads the configuration, or returns null when billing is not wired up.
 *
 * Null is the deliberate local-development and test posture: every check
 * short-circuits to "allowed" so `bun dev`, the Vitest suites, and the
 * Playwright harness keep working without a billing account, the same way
 * `STICKER_FACTORY_MOCK_SERVICES` stands in for the AI gateway. Production
 * sets both variables and the gate becomes real.
 */
export function subscriptionConfig(): SubscriptionConfig | null {
  const baseURL = process.env.RX_SUBSCRIPTION_URL?.trim();
  const apiKey = process.env.RX_SUBSCRIPTION_API_KEY?.trim();
  if (!baseURL || !apiKey) return null;
  return { baseURL: baseURL.replace(/\/+$/, ""), apiKey };
}

/** Whether entitlement and credit checks are enforced at all. */
export function subscriptionEnabled(): boolean {
  return subscriptionConfig() !== null;
}
