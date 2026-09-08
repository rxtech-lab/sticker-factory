import { ApiError } from "@/lib/http/errors";
import { requestBillingEnvironment } from "./environment";
import { subscriptionConfig, type SubscriptionConfig, type BillingEnvironment } from "./config";

/**
 * The slice of the RxSubscription `/api/v1` surface this server uses.
 *
 * Only the operations a secret key must perform: reading what a user is
 * entitled to, and holding, charging, or returning credits around a generation
 * job. Everything the app needs for its paywall — the catalog, purchases,
 * checkout, the App Store bridge — it fetches directly with its publishable
 * key, so none of that is proxied here.
 */

export interface EntitlementBalance {
  unit: string;
  name: string;
  amount: number;
  available: number;
  precision: number;
}

export interface Entitlements {
  roles: string[];
  permissions: string[];
  plans: { planKey: string; planName: string; status: string; billingProvider: string }[];
  usage: UsageAllowance[];
  balances: EntitlementBalance[];
}

export interface Reservation {
  reservationId: string;
  amount: number;
  available: number;
  expiresAt: string;
  status: string;
  duplicate: boolean;
}

export interface ReservationSettlement {
  reservationId: string;
  operationRequestedAmount: number;
  operationSettledAmount: number;
  operationShortfallAmount: number;
  remainingReserved: number;
  balanceAfter: number;
  status: string;
  duplicate: boolean;
}

/** The shape RxSubscription returns on failure. */
interface SubscriptionErrorBody {
  error?: string;
  error_description?: string;
  available?: number;
  required?: number;
}

export class SubscriptionServiceError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly body: SubscriptionErrorBody = {},
  ) {
    super(message);
    this.name = "SubscriptionServiceError";
  }
}

/** Raised when a user simply cannot afford the operation. Callers map this to 402. */
export class InsufficientCreditsError extends Error {
  constructor(
    readonly available: number,
    readonly required: number,
  ) {
    super(`Insufficient credits: ${available} available, ${required} required`);
    this.name = "InsufficientCreditsError";
  }
}

const TIMEOUT_MS = 10_000;

async function call<T>(
  config: SubscriptionConfig,
  method: string,
  path: string,
  options: { query?: Record<string, string>; body?: unknown } = {},
): Promise<T> {
  const url = new URL(`${config.baseURL}/api/v1/${path}`);
  for (const [key, value] of Object.entries(options.query ?? {})) {
    url.searchParams.set(key, value);
  }

  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: {
        "x-api-key": config.apiKey,
        accept: "application/json",
        ...(options.body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });
  } catch (error) {
    // A billing service that is down must not read as "this user has no
    // credits". Surfacing it as its own failure keeps the two apart in logs
    // and gives the client a message worth retrying on.
    throw new SubscriptionServiceError(
      503,
      "SUBSCRIPTION_UNAVAILABLE",
      `The subscription service could not be reached: ${(error as Error).message}`,
    );
  }

  if (response.ok) {
    return (await response.json()) as T;
  }

  const body = (await response.json().catch(() => ({}))) as SubscriptionErrorBody;
  if (body.error === "insufficient_balance") {
    throw new InsufficientCreditsError(body.available ?? 0, body.required ?? 0);
  }
  throw new SubscriptionServiceError(
    response.status,
    body.error ?? "SUBSCRIPTION_ERROR",
    body.error_description ?? `The subscription service returned ${response.status}`,
    body,
  );
}

/** Throws when billing is unconfigured — callers must check `subscriptionEnabled()` first. */
export async function currentBillingEnvironment(): Promise<BillingEnvironment | null> {
  return subscriptionConfig(await requestBillingEnvironment())?.environment ?? null;
}

async function requireConfig(environment?: BillingEnvironment | null): Promise<SubscriptionConfig> {
  const config = subscriptionConfig(environment === undefined ? await requestBillingEnvironment() : environment);
  if (!config) {
    throw new ApiError(
      503,
      "SUBSCRIPTION_NOT_CONFIGURED",
      "Billing is not configured on this server",
    );
  }
  return config;
}

export async function fetchEntitlements(rxlabUserId: string): Promise<Entitlements> {
  return call<Entitlements>(await requireConfig(), "GET", "entitlements", {
    query: { rxlabUserId },
  });
}

export async function reserveCredits(input: {
  rxlabUserId: string;
  unit: string;
  amount: number;
  idempotencyKey: string;
  description: string;
  metadata?: Record<string, unknown>;
  expiresInSeconds?: number;
}): Promise<Reservation> {
  return call<Reservation>(
    await requireConfig(),
    "POST",
    "balances/reserve",
    { body: input },
  );
}

export async function settleReservation(input: {
  reservationId: string;
  amount: number;
  idempotencyKey: string;
  description?: string;
  metadata?: Record<string, unknown>;
}, environment?: BillingEnvironment | null): Promise<ReservationSettlement> {
  return call<ReservationSettlement>(await requireConfig(environment), "POST", `balances/reservations/${input.reservationId}/settle`, {
    body: {
      amount: input.amount,
      idempotencyKey: input.idempotencyKey,
      description: input.description,
      metadata: input.metadata,
      final: true,
    },
  });
}

export async function releaseReservation(input: {
  reservationId: string;
  idempotencyKey: string;
  reason?: string;
}, environment?: BillingEnvironment | null): Promise<void> {
  await call(await requireConfig(environment), "POST", `balances/reservations/${input.reservationId}/release`, {
    body: { idempotencyKey: input.idempotencyKey, reason: input.reason },
  });
}


export interface UsageAllowance {
  key: string; used: number; reserved?: number; limit: number | null;
  remaining: number | null; resetsAt: string | null;
}
export const QUICK_MODE_USAGE_ITEM = "quick_mode_allowance";
export async function fetchUsage(rxlabUserId: string) {
  return call<{ usage: UsageAllowance[] }>(await requireConfig(), "GET", "usage", { query: { rxlabUserId } });
}
/** The deployed usage API records one attempt and enforces the server's allowance. */
export async function recordGenerationUsage(rxlabUserId: string, jobId: string) {
  return call<{ allowed: boolean; reason?: string }>(await requireConfig(), "POST", "usage", { body: {
    rxlabUserId, item: QUICK_MODE_USAGE_ITEM, amount: 1, idempotencyKey: jobId, metadata: { jobId },
  } });
}
