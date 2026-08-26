import { requireApiPrincipal, type ApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase, type Database } from "@/lib/db/client";
import { errorResponse } from "@/lib/http/errors";
import { ensureUser } from "@/lib/services/users";

export async function withApiAuth(
  request: Request,
  action: (principal: ApiPrincipal, db: Database) => Promise<Response>,
): Promise<Response> {
  const requestId = request.headers.get("x-request-id")?.slice(0, 80) || crypto.randomUUID();
  try {
    const principal = await requireApiPrincipal(request);
    const db = getDatabase();
    await ensureUser(db, principal);
    const response = await action(principal, db);
    response.headers.set("x-request-id", requestId);
    return response;
  } catch (error) {
    const response = errorResponse(error, requestId);
    response.headers.set("x-request-id", requestId);
    return response;
  }
}
