import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { getPetRoomArt } from "@/lib/services/pet-rooms";

/**
 * One of the owner's rooms, owned or on offer, as a portrait WebP. A room is drawn once, so the
 * ETag names the drawing and a client that has it skips the bytes.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const id = z.string().uuid().safeParse(new URL(request.url).searchParams.get("id"));
    if (!id.success) throw new ApiError(400, "INVALID_QUERY", "id must be a room id");
    const { etag, bytes } = await getPetRoomArt(db, principal.sub, id.data, request.headers.get("if-none-match"));
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/webp" } });
  });
}
