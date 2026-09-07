import { withApiAuth } from "@/lib/http/handler";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { appClipAllowance } from "@/lib/subscription/app-clip";

// Driver errors wrap the PostgreSQL cause in a query error. Record only identifiers/statuses:
// the outer message can contain SQL parameters, and upstream messages can contain account data.
function failureCauses(error: unknown) {
  const causes: { type: string; code?: string; status?: number }[] = [];
  let current = error;
  for (let depth = 0; current instanceof Error && depth < 5; depth++) {
    const cause = current as Error & { code?: unknown; status?: unknown };
    causes.push({
      type: cause.name,
      code: typeof cause.code === "string" ? cause.code : undefined,
      status: typeof cause.status === "number" ? cause.status : undefined,
    });
    current = cause.cause;
  }
  return causes;
}

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db, context) => {
    try { return noStoreJson(await appClipAllowance(db, principal.sub)); }
    catch (error) {
      if (error instanceof ApiError) throw error;
      const causes = failureCauses(error);
      context.log("app_clip_allowance_failed", { causes });
      if (causes.some(cause => cause.code === "42703" || cause.code === "42P01")) {
        throw new ApiError(503, "APP_CLIP_SCHEMA_NOT_READY", "Quick generation is being updated. Please try again shortly.");
      }
      throw new ApiError(503, "APP_CLIP_USAGE_UNAVAILABLE", "Your daily allowance could not be refreshed. Please try again.");
    }
  });
}
