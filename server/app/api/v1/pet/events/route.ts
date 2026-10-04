import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { integerQuery } from "@/lib/http/query";
import { listPetEvents } from "@/lib/services/pet-state";

/** The current pet's diary, newest first: every stat change, what caused it, and debug detail. */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const url = new URL(request.url);
    const limit = integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 100, defaultValue: 30 })!;
    return noStoreJson(await listPetEvents(db, principal.sub, { limit, cursor: url.searchParams.get("cursor") }));
  });
}
