import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { integerQuery } from "@/lib/http/query";
import { listPetMemories } from "@/lib/services/pet-memory";

/**
 * What the current pet remembers: nearest by meaning to `q` when given — what the phone recalls
 * before the pet answers its owner's words — otherwise most important first.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const url = new URL(request.url);
    const limit = integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 50, defaultValue: 20 })!;
    const query = url.searchParams.get("q")?.slice(0, 500) ?? null;
    return noStoreJson(await listPetMemories(db, principal.sub, { query, limit }));
  });
}
