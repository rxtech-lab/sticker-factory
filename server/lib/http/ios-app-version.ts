import { ApiError } from "@/lib/http/errors";

export const IOS_APP_VERSION_HEADER = "x-ios-app-version";

/**
 * Refuses sticker-list reads from an outdated iOS app without applying the same requirement to the
 * web OAuth client, which uses these endpoints too. The gate is deliberately configured at
 * runtime: raising the minimum should not require a server release.
 */
export function requireSupportedIOSAppVersion(request: Request, clientId: string): void {
  const minimum = process.env.IOS_MINIMUM_APP_VERSION?.trim();
  if (!minimum) return;

  const configuredIOSClientId = process.env.IOS_OAUTH_CLIENT_ID?.trim();
  const current = request.headers.get(IOS_APP_VERSION_HEADER)?.trim();
  const isIOSRequest = Boolean(current) || Boolean(configuredIOSClientId && clientId === configuredIOSClientId);
  if (!isIOSRequest) return;

  const minimumParts = parseVersion(minimum);
  if (!minimumParts) {
    throw new ApiError(
      503,
      "IOS_MINIMUM_VERSION_INVALID",
      "The minimum supported iOS app version is not configured correctly",
    );
  }

  const currentParts = current ? parseVersion(current) : null;
  if (!currentParts || compareVersions(currentParts, minimumParts) < 0) {
    throw new ApiError(
      426,
      "IOS_APP_UPDATE_REQUIRED",
      `Update Winky Sticker House to version ${minimum} or later to view your stickers.`,
      { currentVersion: current || null, minimumVersion: minimum },
    );
  }
}

function parseVersion(value: string): number[] | null {
  if (!/^\d+(?:\.\d+){0,2}$/.test(value)) return null;
  const parts = value.split(".").map(Number);
  return parts.every(Number.isSafeInteger) ? parts : null;
}

function compareVersions(left: number[], right: number[]): number {
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}
