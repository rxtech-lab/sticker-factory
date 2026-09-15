import { z } from "zod";
import { ApiError } from "@/lib/http/errors";

/**
 * The identity provider's half of account deletion.
 *
 * rxlab-auth owns whether the account exists; this application owns the user's stickers. Both keep
 * their own copy of the same deadline, and the app is what keeps them in step — the IdP notifies
 * nobody when it finalizes.
 *
 * The `/api/oauth/account-deletion` surface speaks snake_case and NumericDate (epoch seconds),
 * unlike the camelCase/ISO shape on the IdP's cookie-authenticated routes. We forward the caller's
 * own bearer token rather than acting with app credentials: deleting an account is the user's
 * decision to make, and the token is the only proof we have that they made it.
 */

const DeletionStateSchema = z.object({
  deletion_pending: z.boolean(),
  deletion_scheduled_at: z.number().int().nullable().optional(),
  deletion_requested_at: z.number().int().nullable().optional(),
  already_scheduled: z.boolean().optional(),
  cancelled: z.boolean().optional(),
});

export interface IdpDeletionState {
  pending: boolean;
  scheduledAt: Date | null;
  requestedAt: Date | null;
  alreadyScheduled: boolean;
}

function toDate(seconds: number | null | undefined): Date | null {
  return typeof seconds === "number" ? new Date(seconds * 1000) : null;
}

function deletionEndpoint(): string {
  const issuer = process.env.AUTH_ISSUER;
  if (!issuer) {
    throw new ApiError(503, "AUTH_NOT_CONFIGURED", "Account deletion is not configured");
  }
  return `${issuer.replace(/\/$/, "")}/api/oauth/account-deletion`;
}

/** The caller's `Authorization` header, verbatim. Missing is unreachable — `withApiAuth` ran first. */
function bearerHeader(request: Request): string {
  const header = request.headers.get("authorization");
  if (!header) throw new ApiError(401, "INVALID_ACCESS_TOKEN", "The request has no access token");
  return header;
}

async function callIdp(request: Request, method: "GET" | "POST" | "DELETE"): Promise<IdpDeletionState> {
  let response: Response;
  try {
    response = await fetch(deletionEndpoint(), {
      method,
      headers: { authorization: bearerHeader(request), accept: "application/json" },
      cache: "no-store",
    });
  } catch (error) {
    // A network failure here is not the user's fault and not retryable by them in any useful way,
    // so it must not look like a rejected request.
    console.error("Identity provider account-deletion request failed:", error);
    throw new ApiError(502, "IDENTITY_PROVIDER_UNAVAILABLE", "Could not reach the account service");
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    if (response.status === 403 && body.includes("insufficient_scope")) {
      // The app was authorized before it asked for `write:profile`. Only a fresh sign-in can fix it,
      // so say so specifically instead of reporting a generic refusal.
      throw new ApiError(
        403,
        "ACCOUNT_DELETION_SCOPE_REQUIRED",
        "Sign in again to grant permission to delete this account",
      );
    }
    if (response.status === 401) {
      throw new ApiError(401, "INVALID_ACCESS_TOKEN", "The access token is no longer valid");
    }
    console.error(`Identity provider account-deletion ${method} returned ${response.status}: ${body.slice(0, 500)}`);
    throw new ApiError(502, "IDENTITY_PROVIDER_UNAVAILABLE", "The account service rejected the request");
  }

  const parsed = DeletionStateSchema.safeParse(await response.json().catch(() => null));
  if (!parsed.success) {
    console.error("Identity provider account-deletion response did not parse:", parsed.error.flatten());
    throw new ApiError(502, "IDENTITY_PROVIDER_UNAVAILABLE", "The account service returned an unexpected response");
  }

  return {
    pending: parsed.data.deletion_pending,
    scheduledAt: toDate(parsed.data.deletion_scheduled_at),
    requestedAt: toDate(parsed.data.deletion_requested_at),
    alreadyScheduled: parsed.data.already_scheduled ?? false,
  };
}

export function getIdpDeletionState(request: Request): Promise<IdpDeletionState> {
  return callIdp(request, "GET");
}

/** Idempotent at the IdP: re-posting returns the existing schedule rather than sliding the deadline. */
export function scheduleIdpDeletion(request: Request): Promise<IdpDeletionState> {
  return callIdp(request, "POST");
}

export function cancelIdpDeletion(request: Request): Promise<IdpDeletionState> {
  return callIdp(request, "DELETE");
}
