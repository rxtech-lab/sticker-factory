import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { getPetItemArt, PET_ITEM_MAX_SIZE, PET_ITEM_MIN_SIZE } from "@/lib/services/pet-items";

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const query = new URL(request.url).searchParams;
    const index = integerQuery(query.get("index"), { name: "index", min: 0, max: 3, defaultValue: 0 })!;
    const size = integerQuery(query.get("size"), {
      name: "size", min: PET_ITEM_MIN_SIZE, max: PET_ITEM_MAX_SIZE, defaultValue: 256,
    })!;
    const { etag, bytes } = await getPetItemArt(
      db, principal.sub, index, size, request.headers.get("if-none-match"), query.get("artKey"),
    );
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/webp" } });
  });
}
