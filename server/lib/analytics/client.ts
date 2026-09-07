"use client";

import { analyticsPath, errorCategory } from "./shared";
import type { Analytics, logEvent } from "firebase/analytics";
type BrowserAnalytics = { analytics: Analytics; logEvent: typeof logEvent };

let analyticsPromise: Promise<BrowserAnalytics | null> | undefined;
function getBrowserAnalytics(): Promise<BrowserAnalytics | null> {
  if (typeof window === "undefined" || process.env.NEXT_PUBLIC_ANALYTICS_ENABLED !== "true") return Promise.resolve(null);
  analyticsPromise ??= (async () => {
    const config = {
      apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY,
      authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN,
      projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID,
      storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET,
      messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID,
      appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID,
      measurementId: process.env.NEXT_PUBLIC_FIREBASE_MEASUREMENT_ID,
    };
    if (!config.apiKey || !config.projectId || !config.appId || !config.measurementId) return null;
    const [{ getApps, initializeApp }, { isSupported, initializeAnalytics, logEvent }] = await Promise.all([import("firebase/app"), import("firebase/analytics")]);
    if (!await isSupported()) return null;
    const app = getApps().find((app) => app.name === "web-analytics") ?? initializeApp(config, "web-analytics");
    const analytics = initializeAnalytics(app, { config: {
      send_page_view: false,
      page_location: window.location.origin + analyticsPath(window.location.pathname),
      page_title: analyticsPath(window.location.pathname), page_referrer: "",
      allow_google_signals: false, allow_ad_personalization_signals: false,
    } });
    return { analytics, logEvent };
  })().catch(() => null);
  return analyticsPromise;
}

async function emit(name: string, params: Record<string, string | number>, path: string): Promise<void> {
  try {
    const client = await getBrowserAnalytics();
    if (!client) return;
    client.logEvent(client.analytics, name, { ...params, source: "web", page_location: window.location.origin + analyticsPath(path), page_title: analyticsPath(path), page_referrer: "" });
  } catch { /* Analytics must never break the page or recursively report itself. */ }
}

let lastPath: string | undefined;
export function recordPageView(path: string): void {
  if (lastPath === path) return;
  lastPath = path;
  void emit("page_view", {}, path);
}

let budgetStart = 0;
let eventCount = 0;
function withinBudget(): boolean {
  if (Date.now() - budgetStart > 60_000) { budgetStart = Date.now(); eventCount = 0; }
  return eventCount++ < 30;
}
export function recordBrowserError(error: unknown, kind: "runtime" | "unhandled_rejection" | "react" = "react"): void {
  if (typeof window !== "undefined" && withinBudget()) void emit("web_error", { error_type: errorCategory(error), error_kind: kind }, window.location.pathname);
}

let installed = false;
export function installBrowserReporting(): void {
  if (installed || process.env.NEXT_PUBLIC_ANALYTICS_ENABLED !== "true") return;
  installed = true;
  window.addEventListener("error", (event) => recordBrowserError(event.error, "runtime"));
  window.addEventListener("unhandledrejection", (event) => recordBrowserError(event.reason, "unhandled_rejection"));
  // Preserve original console output; send severity counts only, never message text or arguments.
  for (const level of ["log", "info", "warn", "error"] as const) {
    const original = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      original(...args);
      if (withinBudget()) void emit("web_log", { log_level: level }, window.location.pathname);
    };
  }
}
