import type { Database } from "@/lib/db/client";
import {
  getApnsConfig,
  sendPushes,
  type ApnsConfig,
  type ApnsPush,
  type ApnsResult,
} from "@/lib/notifications/apns";
import { disableDeviceToken, listActiveDeviceTokens } from "@/lib/services/devices";
import { traceEvent } from "@/lib/observability/trace";

/**
 * Telling the phone its pet changed pose, so the widget and the watch follow without the app open.
 *
 * Silent: nobody asked to be interrupted because they sent a sticker. The app wakes in the
 * background, fetches the new pose, and hands it to the widget and the watch. iOS rations these
 * pushes, so it is a nudge, not a guarantee — the app also refreshes whenever it comes forward.
 */

/** What the app reads to tell this push from a generation banner. */
export const PET_STATUS_PUSH_KIND = "pet-status";

export function petStatusPayload(): Record<string, unknown> {
  return { aps: { "content-available": 1 }, kind: PET_STATUS_PUSH_KIND };
}

/**
 * Pushes "your pet moved" to every device its owner is signed in on.
 *
 * Never throws: it runs after the reading has been stored, where an error has nobody to reach. One
 * collapse id per user, so a burst of sends leaves one wake-up waiting, not a queue of them.
 */
export async function notifyPetStatusChanged(
  db: Database,
  userId: string,
  options: {
    config?: ApnsConfig;
    /** Injected by tests, which have no `.p8` and no wish to open a socket to Apple. */
    send?: (pushes: ApnsPush[], config: ApnsConfig) => Promise<ApnsResult[]>;
  } = {},
): Promise<void> {
  try {
    const config = options.config ?? getApnsConfig();
    if (!config) {
      traceEvent("push:skipped", { userId, kind: PET_STATUS_PUSH_KIND, reason: "APNS_NOT_CONFIGURED" });
      return;
    }
    const devices = await listActiveDeviceTokens(db, userId);
    if (devices.length === 0) return;
    const payload = petStatusPayload();
    const pushes: ApnsPush[] = devices.map((device) => ({
      token: device.token,
      environment: device.environment,
      payload,
      collapseId: `pet-${userId}`,
      // Apple requires background pushes at priority 5, and drops them at 10.
      pushType: "background",
      priority: "5",
    }));
    const results = await (options.send ?? sendPushes)(pushes, config);
    for (const result of results) {
      if (result.permanentlyGone) {
        await disableDeviceToken(db, result.token, result.reason ?? `HTTP ${result.status}`);
      }
    }
    traceEvent("push:sent", {
      userId,
      kind: PET_STATUS_PUSH_KIND,
      delivered: results.filter((result) => result.ok).length,
      failed: results.filter((result) => !result.ok).map((result) => result.reason ?? result.status),
    });
  } catch (error) {
    console.error("[push] notifyPetStatusChanged failed", { userId, error });
  }
}
