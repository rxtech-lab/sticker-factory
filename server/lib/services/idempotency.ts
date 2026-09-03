import { createHash } from "node:crypto";
import { and, eq, lte } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { idempotencyKeys } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

export interface IdempotentResult<T> {
  status: number;
  body: T;
  replayed: boolean;
}

function stableJson(value: unknown): string {
  if (value === undefined) return '"__undefined__"';
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${stableJson(item)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

export function requestHash(value: unknown): string {
  return createHash("sha256").update(stableJson(value)).digest("hex");
}

export function idempotencyUuid(ownerId: string, operation: string, key: string): string {
  const hex = createHash("sha256").update(`${ownerId}\0${operation}\0${key}`).digest("hex").slice(0, 32).split("");
  hex[12] = "5";
  hex[16] = ((Number.parseInt(hex[16], 16) & 0x3) | 0x8).toString(16);
  const value = hex.join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

export function requireIdempotencyKey(request: Request): string {
  const key = request.headers.get("idempotency-key")?.trim();
  if (!key) throw new ApiError(400, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key is required");
  if (key.length < 8 || key.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(key)) {
    throw new ApiError(400, "INVALID_IDEMPOTENCY_KEY", "Idempotency-Key must be 8-128 URL-safe characters");
  }
  return key;
}

export async function executeIdempotent<T>(
  db: Database,
  options: { ownerId: string; operation: string; key: string; request: unknown },
  action: () => Promise<{ status: number; body: T }>,
): Promise<IdempotentResult<T>> {
  const hash = requestHash(options.request);
  const now = new Date();
  const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000);
  const identity = and(
    eq(idempotencyKeys.ownerId, options.ownerId),
    eq(idempotencyKeys.operation, options.operation),
    eq(idempotencyKeys.key, options.key),
  );

  await db.delete(idempotencyKeys).where(and(identity, lte(idempotencyKeys.expiresAt, now)));

  const inserted = await db.insert(idempotencyKeys).values({
    ownerId: options.ownerId,
    operation: options.operation,
    key: options.key,
    requestHash: hash,
    createdAt: now,
    expiresAt,
  }).onConflictDoNothing().returning({ key: idempotencyKeys.key });

  if (inserted.length === 0) {
    const existing = await db.select().from(idempotencyKeys).where(identity).then(firstRow);
    if (!existing || existing.requestHash !== hash) {
      throw new ApiError(409, "IDEMPOTENCY_KEY_REUSED", "This key was already used with a different request");
    }
    if (existing.responseStatus === null) {
      throw new ApiError(409, "REQUEST_IN_PROGRESS", "A request with this idempotency key is still running");
    }
    return { status: existing.responseStatus, body: existing.responseJson as T, replayed: true };
  }

  try {
    const result = await action();
    await db.update(idempotencyKeys).set({
      responseStatus: result.status,
      responseJson: result.body,
    }).where(identity);
    return { ...result, replayed: false };
  } catch (error) {
    if (error instanceof ApiError && error.status < 500) {
      await db.delete(idempotencyKeys).where(identity);
    } else {
      await db.update(idempotencyKeys).set({
        expiresAt: new Date(Date.now() + 15 * 60 * 1000),
      }).where(identity);
    }
    throw error;
  }
}
