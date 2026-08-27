import { and, eq, isNull } from "drizzle-orm";
import type { RegisterDeviceRequest } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { deviceTokens, type DeviceTokenRow } from "@/lib/db/schema";

/**
 * Records where this install can be reached, and moves the token if it changed hands.
 *
 * The upsert targets the token, so signing a second account in on the same phone reassigns the row
 * instead of adding one: iOS issues one token per install, and two owners claiming it would push
 * one person's stickers to another person's lock screen.
 *
 * It also clears `disabled_at`. A token is disabled when APNs reports it gone, but the app
 * announcing itself is newer evidence than that — a reinstall produces a fresh registration for a
 * token Apple had already written off.
 */
export async function registerDeviceToken(
  db: Database,
  ownerId: string,
  input: RegisterDeviceRequest,
): Promise<{ token: string; registeredAt: string }> {
  const now = new Date();
  const values = {
    token: input.token,
    userId: ownerId,
    platform: input.platform,
    environment: input.environment,
    bundleId: input.bundleId ?? null,
    appVersion: input.appVersion ?? null,
  };
  await db.insert(deviceTokens).values({
    ...values,
    createdAt: now,
    updatedAt: now,
    lastSeenAt: now,
  }).onConflictDoUpdate({
    target: deviceTokens.token,
    set: {
      ...values,
      updatedAt: now,
      lastSeenAt: now,
      disabledAt: null,
      disabledReason: null,
    },
  });
  return { token: input.token, registeredAt: now.toISOString() };
}

/**
 * Stops pushing to a token, on sign-out.
 *
 * Scoped to the caller so one account cannot silence another's device, and idempotent so signing
 * out twice — or out of an install whose token already moved on — is not an error.
 */
export async function unregisterDeviceToken(db: Database, ownerId: string, token: string): Promise<void> {
  await db.delete(deviceTokens)
    .where(and(eq(deviceTokens.token, token), eq(deviceTokens.userId, ownerId)));
}

/** Every device this user can currently be reached on. */
export async function listActiveDeviceTokens(db: Database, ownerId: string): Promise<DeviceTokenRow[]> {
  return db.select().from(deviceTokens)
    .where(and(eq(deviceTokens.userId, ownerId), isNull(deviceTokens.disabledAt)));
}

/**
 * Marks a token APNs has rejected for good.
 *
 * Kept as a tombstone rather than deleted so the same dead token is not re-tried on every
 * subsequent turn, and so a later registration of it is visibly a revival.
 */
export async function disableDeviceToken(db: Database, token: string, reason: string): Promise<void> {
  await db.update(deviceTokens)
    .set({ disabledAt: new Date(), disabledReason: reason.slice(0, 200), updatedAt: new Date() })
    .where(eq(deviceTokens.token, token));
}
