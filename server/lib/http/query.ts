import { ApiError } from "@/lib/http/errors";

export function integerQuery(
  value: string | null,
  options: { name: string; min: number; max: number; defaultValue?: number },
): number | undefined {
  if (value === null || value === "") return options.defaultValue;
  if (!/^\d+$/.test(value)) throw new ApiError(400, "INVALID_QUERY", `${options.name} must be an integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < options.min || parsed > options.max) {
    throw new ApiError(400, "INVALID_QUERY", `${options.name} must be between ${options.min} and ${options.max}`);
  }
  return parsed;
}

export function textQuery(
  value: string | null,
  options: { name: string; maxLength: number },
): string | undefined {
  if (value === null) return undefined;
  const parsed = value.trim();
  if (parsed === "") return undefined;
  if (parsed.length > options.maxLength) {
    throw new ApiError(400, "INVALID_QUERY", `${options.name} must be at most ${options.maxLength} characters`);
  }
  return parsed;
}
