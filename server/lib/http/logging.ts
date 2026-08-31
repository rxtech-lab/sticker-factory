import { ZodError } from "zod";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { ApiError } from "@/lib/http/errors";

const MAX_STRING_LENGTH = 500;
const MAX_ARRAY_LENGTH = 25;
const MAX_DEPTH = 5;
const SENSITIVE_FIELD = /^(authorization|proxy-authorization|cookie|set-cookie|password|token|access[-_]?token|refresh[-_]?token|private[-_]?key|secret|api[-_]?key)$/i;

export interface ApiRequestLogContext {
  requestId: string;
  method: string;
  path: string;
  log(event: string, fields?: Record<string, unknown>): void;
}

function truncate(value: string): string {
  return value.length > MAX_STRING_LENGTH
    ? `${value.slice(0, MAX_STRING_LENGTH)}…[${value.length - MAX_STRING_LENGTH} more chars]`
    : value;
}

/** Keeps diagnostic fields bounded and prevents an accidentally supplied credential from reaching logs. */
export function safeLogValue(value: unknown, depth = 0, seen = new WeakSet<object>()): unknown {
  if (value === null || typeof value === "boolean" || typeof value === "number") return value;
  if (typeof value === "string") return truncate(value);
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "undefined") return undefined;
  if (depth >= MAX_DEPTH) return "[depth limit]";

  if (Array.isArray(value)) {
    const items = value.slice(0, MAX_ARRAY_LENGTH).map((item) => safeLogValue(item, depth + 1, seen));
    if (value.length > MAX_ARRAY_LENGTH) items.push(`[${value.length - MAX_ARRAY_LENGTH} more items]`);
    return items;
  }

  if (value instanceof Date) return value.toISOString();
  if (value instanceof Error) return { name: value.name, message: truncate(value.message) };
  if (typeof value !== "object") return String(value);
  if (seen.has(value)) return "[circular]";
  seen.add(value);

  const result: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    result[key] = SENSITIVE_FIELD.test(key) ? "[redacted]" : safeLogValue(item, depth + 1, seen);
  }
  return result;
}

export function apiRequestMetadata(request: Request, principal?: ApiPrincipal): Record<string, unknown> {
  const url = new URL(request.url);
  return {
    queryKeys: [...new Set(url.searchParams.keys())],
    contentType: request.headers.get("content-type")?.split(";", 1)[0] ?? null,
    contentLength: request.headers.get("content-length") ?? null,
    accept: request.headers.get("accept") ?? null,
    userAgent: request.headers.get("user-agent") ? truncate(request.headers.get("user-agent")!) : null,
    idempotencyKey: request.headers.has("idempotency-key") ? "present" : "missing",
    stickerContract: request.headers.get("x-sticker-contract") ?? null,
    oauthClient: principal?.clientId ?? null,
    scopeCount: principal?.scopes.length ?? null,
  };
}

export function apiFailureDetails(error: unknown): Record<string, unknown> {
  if (error instanceof ApiError) {
    return {
      type: error.name,
      code: error.code,
      message: error.message,
      details: safeLogValue(error.details),
    };
  }

  if (error instanceof ZodError) {
    return {
      type: error.name,
      code: "VALIDATION_ERROR",
      message: "The request payload is invalid",
      details: {
        issues: error.issues.map((issue) => safeLogValue(issue)),
      },
    };
  }

  if (error instanceof Error) {
    return {
      type: error.name,
      code: "INTERNAL_ERROR",
      message: truncate(error.message),
      stack: error.stack ? truncate(error.stack) : undefined,
    };
  }

  return { type: typeof error, code: "INTERNAL_ERROR", value: safeLogValue(error) };
}

export function createApiRequestLogContext(request: Request, requestId: string): ApiRequestLogContext {
  const method = request.method;
  const path = new URL(request.url).pathname;
  return {
    requestId,
    method,
    path,
    log(event, fields = {}) {
      console.log(`[api:event] ${JSON.stringify({
        requestId,
        method,
        path,
        event,
        fields: safeLogValue(fields),
      })}`);
    },
  };
}
