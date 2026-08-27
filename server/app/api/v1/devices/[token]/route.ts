import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { unregisterDeviceToken } from "@/lib/services/devices";

/**
 * Signing out: stop pushing to this device.
 *
 * Scoped to the caller, so a token can only be dropped by the account currently holding it, and
 * silent about whether anything was deleted — an install signing out of an account it had already
 * been signed out of is not a failure worth reporting.
 */
export async function DELETE(request: Request, context: { params: Promise<{ token: string }> }) {
  return withApiAuth(request, async (principal, db) => {
    const { token } = await context.params;
    await unregisterDeviceToken(db, principal.sub, token);
    return noStoreJson({ token, unregistered: true });
  });
}
