import { CreatePackRequestSchema, PackSortSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createPack, listMarketplacePacks, listOwnPacks } from "@/lib/services/packs";

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const url = new URL(request.url);
    const limit = integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 100, defaultValue: 30 });
    const cursor = url.searchParams.get("cursor");
    const query = url.searchParams.get("q");
    // `mine=true` is the authoring list: it includes drafts, which browse must never show.
    if (url.searchParams.get("mine") === "true") {
      return noStoreJson(await listOwnPacks(db, principal.sub, { limit, cursor, query }));
    }
    const sort = PackSortSchema.safeParse(url.searchParams.get("sort"));
    return noStoreJson(await listMarketplacePacks(db, principal.sub, {
      limit,
      cursor,
      sort: sort.success ? sort.data : "recent",
      query,
    }));
  });
}

export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, CreatePackRequestSchema.parse);
    const key = requireIdempotencyKey(request);
    const result = await executeIdempotent(db, {
      ownerId: principal.sub,
      operation: "create-pack",
      key,
      request: body,
    }, async () => ({ status: 201, body: await createPack(db, principal.sub, body) }));
    return noStoreJson(result.body, {
      status: result.status,
      headers: { "idempotency-replayed": String(result.replayed) },
    });
  });
}
