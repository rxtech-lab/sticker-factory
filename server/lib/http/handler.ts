import { requireApiPrincipal, type ApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase, type Database } from "@/lib/db/client";
import { errorResponse } from "@/lib/http/errors";
import {
  apiFailureDetails,
  apiRequestMetadata,
  createApiRequestLogContext,
  type ApiRequestLogContext,
} from "@/lib/http/logging";
import { elapsedMs, formatTimings, runTimed, serverTimingHeader, timeStage } from "@/lib/http/timing";
import { ensureUser } from "@/lib/services/users";

export async function withApiAuth(
  request: Request,
  action: (principal: ApiPrincipal, db: Database, context: ApiRequestLogContext) => Promise<Response>,
): Promise<Response> {
  const requestId = request.headers.get("x-request-id")?.slice(0, 80) || crypto.randomUUID();
  const context = createApiRequestLogContext(request, requestId);
  return runTimed(async () => {
    let status = 0;
    let stage = "auth";
    let principal: ApiPrincipal | undefined;
    let failure: unknown;
    let failureStage: string | undefined;
    try {
      const authenticatedPrincipal = await timeStage("auth", () => requireApiPrincipal(request));
      principal = authenticatedPrincipal;
      const requiresUserRow = request.method !== "GET" && request.method !== "HEAD";
      stage = requiresUserRow ? "ensure-user" : "handler";
      const db = getDatabase();
      if (requiresUserRow) {
        await timeStage("ensure-user", () => ensureUser(db, authenticatedPrincipal));
      }
      stage = "handler";
      const response = await timeStage("handler", () => action(authenticatedPrincipal, db, context));
      status = response.status;
      response.headers.set("x-request-id", requestId);
      return withTimings(response);
    } catch (error) {
      failure = error;
      failureStage = stage;
      const response = errorResponse(error, requestId);
      status = response.status;
      response.headers.set("x-request-id", requestId);
      return withTimings(response);
    } finally {
      const entry = {
        requestId,
        method: context.method,
        path: context.path,
        status,
        durationMs: Math.round(elapsedMs() * 10) / 10,
        timings: formatTimings(),
        request: apiRequestMetadata(request, principal),
        ...(failureStage ? { failureStage, error: apiFailureDetails(failure) } : {}),
      };
      const line = `[api] ${JSON.stringify(entry)}`;
      if (status >= 500) console.error(line);
      else if (status >= 400) console.warn(line);
      else console.log(line);
    }
  });
}

function withTimings(response: Response): Response {
  const header = serverTimingHeader();
  if (header) response.headers.set("server-timing", header);
  return response;
}
