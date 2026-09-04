import { afterEach, describe, expect, it } from "vitest";
import { ApiError } from "@/lib/http/errors";
import { IOS_APP_VERSION_HEADER, requireSupportedIOSAppVersion } from "@/lib/http/ios-app-version";

const savedMinimum = process.env.IOS_MINIMUM_APP_VERSION;
const savedIOSClientId = process.env.IOS_OAUTH_CLIENT_ID;

describe("iOS app version gate", () => {
  afterEach(() => {
    restore("IOS_MINIMUM_APP_VERSION", savedMinimum);
    restore("IOS_OAUTH_CLIENT_ID", savedIOSClientId);
  });

  it("is inactive until a minimum version is configured", () => {
    delete process.env.IOS_MINIMUM_APP_VERSION;
    process.env.IOS_OAUTH_CLIENT_ID = "ios-client";

    expect(() => requireSupportedIOSAppVersion(request(), "ios-client")).not.toThrow();
  });

  it("requires the version header from the configured iOS OAuth client", () => {
    process.env.IOS_MINIMUM_APP_VERSION = "1.2";
    process.env.IOS_OAUTH_CLIENT_ID = "ios-client";

    expectApiError(() => requireSupportedIOSAppVersion(request(), "ios-client"), {
      status: 426,
      code: "IOS_APP_UPDATE_REQUIRED",
      message: "Update Winky Sticker House to version 1.2 or later to view your stickers.",
      details: { currentVersion: null, minimumVersion: "1.2" },
    });
  });

  it("rejects older versions and accepts equal or newer dotted versions", () => {
    process.env.IOS_MINIMUM_APP_VERSION = "1.2";
    process.env.IOS_OAUTH_CLIENT_ID = "ios-client";

    expectApiError(() => requireSupportedIOSAppVersion(request("1.1.9"), "ios-client"), {
      status: 426,
      code: "IOS_APP_UPDATE_REQUIRED",
      details: { currentVersion: "1.1.9", minimumVersion: "1.2" },
    });
    expect(() => requireSupportedIOSAppVersion(request("1.2.0"), "ios-client")).not.toThrow();
    expect(() => requireSupportedIOSAppVersion(request("2.0"), "ios-client")).not.toThrow();
  });

  it("does not apply the iOS minimum to a web client", () => {
    process.env.IOS_MINIMUM_APP_VERSION = "9.0";
    process.env.IOS_OAUTH_CLIENT_ID = "ios-client";

    expect(() => requireSupportedIOSAppVersion(request(), "web-client")).not.toThrow();
  });

  it("fails safely when an active minimum is malformed", () => {
    process.env.IOS_MINIMUM_APP_VERSION = "latest";
    process.env.IOS_OAUTH_CLIENT_ID = "ios-client";

    expectApiError(() => requireSupportedIOSAppVersion(request("1.2"), "ios-client"), {
      status: 503,
      code: "IOS_MINIMUM_VERSION_INVALID",
    });
  });
});

function request(version?: string): Request {
  return new Request("https://example.test/api/v1/stickers", {
    headers: version ? { [IOS_APP_VERSION_HEADER]: version } : undefined,
  });
}

function expectApiError(
  action: () => void,
  expected: Partial<Pick<ApiError, "status" | "code" | "message" | "details">>,
): void {
  try {
    action();
    throw new Error("Expected an ApiError");
  } catch (error) {
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject(expected);
  }
}

function restore(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
