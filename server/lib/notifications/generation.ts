import type { Database } from "@/lib/db/client";
import type { GenerationJobRow } from "@/lib/db/schema";
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
 * Announcing the end of a turn to a user who is not watching it.
 *
 * This used to be the app's job — a local notification posted when the client's event stream
 * reached a terminal event. That only ever worked while the app was awake to see it: iOS suspends a
 * backgrounded app within seconds, the stream dies with it, and the one case a banner exists for
 * was the one case it never fired. Generation happens here, so the announcement does too.
 *
 * The client still decides whether to *show* it — a push that lands while the chat is on screen is
 * swallowed, because the screen is already the announcement.
 */

export type GenerationOutcome = "ready" | "plan_ready" | "failed";

/**
 * Job kinds worth interrupting someone for.
 *
 * `cleanup` is a deletion the user already watched confirm, and `export` finishes in a sheet they
 * are looking at. Both would be a banner about housekeeping.
 */
const NOTIFIABLE_JOB_KINDS = new Set<GenerationJobRow["kind"]>([
  "image",
  "edit",
  "animation",
  "chat",
  "plan",
  "compose",
]);

export function isNotifiableJobKind(kind: GenerationJobRow["kind"]): boolean {
  return NOTIFIABLE_JOB_KINDS.has(kind);
}

/** The words on the banner. Planning finishes with a review, not a generated sticker. */
export function generationAlert(outcome: GenerationOutcome, stickerTitle: string): { title: string; body: string } {
  const name = stickerTitle.trim() || "Your sticker";
  if (outcome === "plan_ready") {
    return { title: "Plan ready", body: `The plan for ${name} is ready. Tap to review and confirm it.` };
  }
  return outcome === "ready"
    ? { title: "Sticker ready", body: `${name} finished generating. Tap to take a look.` }
    : { title: "Generation failed", body: `${name} couldn't be generated. Tap to retry.` };
}

export interface GenerationNotification {
  ownerId: string;
  jobId: string;
  stickerId: string;
  stickerTitle: string;
  outcome: GenerationOutcome;
}

/**
 * The APNs payload. `stickerID` is what the app reads back to open the right sticker on a tap.
 *
 * The topic these are sent under is `APNS_BUNDLE_ID` — the *app's* bundle id
 * (`app.rxlab.stickerfactory`), never the Messages extension's.
 *
 * `thread-id` groups a project's banners in Notification Center, so a chatty sticker collapses into
 * one stack rather than burying everything else.
 */
export function generationPayload(notification: GenerationNotification): Record<string, unknown> {
  const alert = generationAlert(notification.outcome, notification.stickerTitle);
  return {
    aps: {
      alert: { title: alert.title, body: alert.body },
      sound: "default",
      "thread-id": notification.stickerId,
    },
    stickerID: notification.stickerId,
    jobID: notification.jobId,
    outcome: notification.outcome,
  };
}

/**
 * Stable per job *and* outcome, so a step that runs twice replaces its own undelivered banner
 * instead of stacking a second one.
 */
export function generationCollapseId(notification: GenerationNotification): string {
  return `gen-${notification.jobId}-${notification.outcome}`;
}

/**
 * Pushes one finished turn to every device its owner is signed in on.
 *
 * Never throws. It is called from the step that has already committed the job's terminal state, and
 * a sticker that was generated successfully must not be reported as failed because Apple timed out.
 */
export async function notifyGenerationFinished(
  db: Database,
  notification: GenerationNotification,
  options: {
    config?: ApnsConfig;
    /** Injected by tests, which have no `.p8` and no wish to open a socket to Apple. */
    send?: (pushes: ApnsPush[], config: ApnsConfig) => Promise<ApnsResult[]>;
  } = {},
): Promise<void> {
  try {
    const config = options.config ?? getApnsConfig();
    const send = options.send ?? sendPushes;
    // No credentials is the normal state locally and in tests. Say so once, quietly, rather than
    // querying for devices that cannot be reached anyway.
    if (!config) {
      traceEvent("push:skipped", { jobId: notification.jobId, reason: "APNS_NOT_CONFIGURED" });
      return;
    }
    const devices = await listActiveDeviceTokens(db, notification.ownerId);
    if (devices.length === 0) return;

    const payload = generationPayload(notification);
    const collapseId = generationCollapseId(notification);
    const pushes: ApnsPush[] = devices.map((device) => ({
      token: device.token,
      environment: device.environment,
      payload,
      collapseId,
    }));

    const results = await send(pushes, config);
    for (const result of results) {
      if (result.permanentlyGone) {
        await disableDeviceToken(db, result.token, result.reason ?? `HTTP ${result.status}`);
      }
    }
    traceEvent("push:sent", {
      jobId: notification.jobId,
      outcome: notification.outcome,
      delivered: results.filter((result) => result.ok).length,
      failed: results.filter((result) => !result.ok).map((result) => result.reason ?? result.status),
    });
  } catch (error) {
    console.error("[push] notifyGenerationFinished failed", { jobId: notification.jobId, error });
  }
}
