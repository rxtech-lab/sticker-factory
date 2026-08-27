import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listLibrarySections } from "@/lib/services/packs";

/**
 * The sectioned library: "My Stickers" first, then one section per installed pack.
 *
 * Separate from `GET /api/v1/stickers` rather than a mode of it, because that endpoint is
 * owner-scoped and every existing caller assumes each row is a sticker it may edit. This one is
 * also intentionally unpaginated — see `listLibrarySections`.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const status = new URL(request.url).searchParams.get("status");
    return noStoreJson(await listLibrarySections(db, principal.sub, {
      status: status === "all" ? "all" : "published",
    }));
  });
}
