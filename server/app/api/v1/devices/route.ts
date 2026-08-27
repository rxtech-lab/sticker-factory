import { RegisterDeviceRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { registerDeviceToken } from "@/lib/services/devices";

/**
 * Tells the server where to reach this install.
 *
 * The app calls this every launch, not just the first: APNs reissues tokens after a restore, an OS
 * upgrade, or a reinstall, and a stale one is indistinguishable from a live one until a push to it
 * bounces. Re-registering is an upsert, so calling it often costs a single write.
 *
 * Deliberately not idempotency-keyed. The registration *is* idempotent, and the token itself is a
 * better key than anything the client could invent for it.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, RegisterDeviceRequestSchema.parse);
    return noStoreJson(await registerDeviceToken(db, principal.sub, body));
  });
}
