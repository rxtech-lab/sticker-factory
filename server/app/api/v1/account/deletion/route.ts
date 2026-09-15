import type { AccountDeletionStateV1 } from "@/lib/contracts/api";
import { cancelIdpDeletion, scheduleIdpDeletion } from "@/lib/auth/idp-account-deletion";
import type { Database } from "@/lib/db/client";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import {
  cancelAccountDeletion,
  getDeletionStatus,
  scheduleAccountDeletion,
  type PendingDeletion,
} from "@/lib/services/account-deletion";

/**
 * Scheduling, reading and cancelling the signed-in user's account deletion.
 *
 * Two systems have to agree: rxlab-auth deletes the account, this server deletes the stickers, and
 * each runs its own timer because the identity provider notifies no one when it finalizes. The
 * ordering below is what keeps a disagreement between them survivable.
 *
 * The session is deliberately left intact throughout. The user stays signed in for the whole grace
 * period so they can change their mind — the recovery path has to be at least as reachable as the
 * damage.
 */

function serialize(pending: PendingDeletion | null): AccountDeletionStateV1 {
  return {
    pendingDeletion: pending !== null,
    deletionScheduledAt: pending?.scheduledAt.toISOString() ?? null,
    deletionRequestedAt: pending?.requestedAt.toISOString() ?? null,
  };
}

/**
 * A GET never writes, so `withApiAuth` skips `ensureUser` and a brand-new install has no row yet.
 * That reads as "no deletion pending", which is exactly right.
 */
async function localStatus(db: Database, userId: string): Promise<PendingDeletion | null> {
  const status = await getDeletionStatus(db, userId);
  return status?.pending ?? null;
}

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    return noStoreJson(serialize(await localStatus(db, principal.sub)));
  });
}

/**
 * Schedule the deletion: **identity provider first, then locally.**
 *
 * The IdP decides — it owns whether the account exists at all — and we adopt the deadline it
 * returns so the two systems name the same instant rather than two deadlines a round-trip apart.
 * If the local write then fails the client sees a 500 and retries; both sides are idempotent, so a
 * retry converges instead of scheduling twice or sliding the date.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const remote = await scheduleIdpDeletion(request);

    const result = await scheduleAccountDeletion(db, principal.sub, {
      scheduledAt: remote.scheduledAt ?? undefined,
    });
    if (!result.ok) {
      if (result.reason === "already_deleted") {
        throw new ApiError(410, "ACCOUNT_ALREADY_DELETED", "This account has already been deleted");
      }
      throw new ApiError(404, "USER_NOT_FOUND", "Account not found");
    }

    return noStoreJson(serialize(result.pending));
  });
}

/**
 * Cancel the deletion: **locally first, then the identity provider.**
 *
 * The reverse order has a failure mode we cannot accept: if the IdP cancelled and our write then
 * failed, this server would purge the stickers of an account that still exists. This way round, a
 * failed forward leaves the account still scheduled for deletion but its work intact — recoverable,
 * and the error tells the client to try again.
 */
export async function DELETE(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const result = await cancelAccountDeletion(db, principal.sub);
    if (!result.ok) {
      if (result.reason === "already_deleted") {
        throw new ApiError(410, "ACCOUNT_ALREADY_DELETED", "This account has already been deleted");
      }
      throw new ApiError(404, "USER_NOT_FOUND", "Account not found");
    }

    await cancelIdpDeletion(request);
    return noStoreJson(serialize(null));
  });
}
