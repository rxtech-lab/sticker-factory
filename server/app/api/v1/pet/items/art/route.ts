import { z } from "zod";
import { PET_SHOP_MAX } from "@/lib/contracts/api";
import { ApiError } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { getPetItemArt, getPetItemArtById, PET_ITEM_MAX_SIZE, PET_ITEM_MIN_SIZE } from "@/lib/services/pet-items";

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const query = new URL(request.url).searchParams;
    const index = integerQuery(query.get("index"), { name: "index", min: 0, max: PET_SHOP_MAX - 1, defaultValue: 0 })!;
    const size = integerQuery(query.get("size"), {
      name: "size", min: PET_ITEM_MIN_SIZE, max: PET_ITEM_MAX_SIZE, defaultValue: 256,
    })!;
    // `item=<id>` names an item on the shelf or in the bag; `index` is a place on the shelf, for
    // apps from before items had pictures of their own.
    const itemId = query.get("item");
    if (itemId !== null && !z.string().uuid().safeParse(itemId).success) {
      throw new ApiError(400, "INVALID_QUERY", "item must be an item id.");
    }
    const { etag, bytes } = itemId
      ? await getPetItemArtById(db, principal.sub, itemId, size, request.headers.get("if-none-match"))
      : await getPetItemArt(db, principal.sub, index, size, request.headers.get("if-none-match"), query.get("artKey"));
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/webp" } });
  });
}
