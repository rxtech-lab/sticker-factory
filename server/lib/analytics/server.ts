import { after } from "next/server";
import { analyticsMethod, analyticsPath } from "./shared";

type ServerEvent = "api_request" | "server_error" | "server_log";
interface EventFields {
  path: string;
  method: string;
  status?: number;
  durationMs?: number;
  logCode?: string;
}
const logCodes = new Set(["upload-intent.validated", "upload-intent.completed", "upload-completion.validated", "upload-completion.completed", "app_clip_allowance_failed"]);

export function serverAnalyticsEnabled(): boolean {
  return process.env.GOOGLE_ANALYTICS_SERVER_ENABLED === "true" && !!process.env.GOOGLE_ANALYTICS_API_SECRET && /^G-[A-Z0-9]+$/.test(process.env.NEXT_PUBLIC_FIREBASE_MEASUREMENT_ID ?? "");
}

/** Operational events use a dedicated synthetic identity, never an authenticated user or device ID. */
export async function sendServerEvent(name: ServerEvent, fields: EventFields): Promise<void> {
  if (!serverAnalyticsEnabled()) return;
  try {
    const query = new URLSearchParams({ measurement_id: process.env.NEXT_PUBLIC_FIREBASE_MEASUREMENT_ID!, api_secret: process.env.GOOGLE_ANALYTICS_API_SECRET! });
    const params: Record<string, string | number> = {
      source: "server", route: analyticsPath(fields.path), method: analyticsMethod(fields.method),
    };
    if (Number.isFinite(fields.status)) params.status_code = fields.status!;
    if (Number.isFinite(fields.durationMs)) params.duration_ms = Math.max(0, Math.round(fields.durationMs!));
    if (fields.logCode) params.log_code = logCodes.has(fields.logCode) ? fields.logCode : "application_event";
    const response = await fetch(`https://www.google-analytics.com/mp/collect?${query}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ client_id: "server.operations", non_personalized_ads: true, events: [{ name, params }] }),
      signal: AbortSignal.timeout(2000),
    });
    if (!response.ok) console.warn("[analytics] Event delivery failed", response.status);
  } catch {
    // Never include the URL (contains the API secret), or fail the application's request.
    console.warn("[analytics] Event delivery unavailable");
  }
}

export function recordServerEvent(name: ServerEvent, fields: EventFields): void {
  if (!serverAnalyticsEnabled()) return;
  try {
    after(() => sendServerEvent(name, fields));
  } catch {
    // A caller outside a Next.js request must await sendServerEvent instead.
    console.warn("[analytics] No request context for event");
  }
}
