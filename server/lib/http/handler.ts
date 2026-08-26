import { requireApiPrincipal, type ApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase, type Database } from "@/lib/db/client";
import { errorResponse } from "@/lib/http/errors";
import { elapsedMs, formatTimings, runTimed, serverTimingHeader, timeStage } from "@/lib/http/timing";
import { ensureUser } from "@/lib/services/users";

export async function withApiAuth(
  request: Request,
  action: (principal: ApiPrincipal, db: Database) => Promise<Response>,
): Promise<Response> {
  const requestId = request.headers.get("x-request-id")?.slice(0, 80) || crypto.randomUUID();
  return runTimed(async () => {
    let status = 0;
    try {
      const principal = await timeStage("auth", () => requireApiPrincipal(request));
      const db = getDatabase();
      await timeStage("ensure-user", () => ensureUser(db, principal));
      const response = await timeStage("handler", () => action(principal, db));
      status = response.status;
      response.headers.set("x-request-id", requestId);
      return withTimings(response);
    } catch (error) {
      const response = errorResponse(error, requestId);
      status = response.status;
      response.headers.set("x-request-id", requestId);
      return withTimings(response);
    } finally {
      const method = request.method;
      const path = new URL(request.url).pathname;
      console.log(`[api] ${method} ${path} ${status} ${Math.round(elapsedMs())}ms ${formatTimings()} requestId=${requestId}`);
    }
  });
}

function withTimings(response: Response): Response {
  const header = serverTimingHeader();
  if (header) response.headers.set("server-timing", header);
  return response;
}
