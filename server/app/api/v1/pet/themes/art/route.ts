import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { getPetThemeArt } from "@/lib/services/pet-themes";

/**
 * One of the places the pet knows, as a portrait WebP. A place is drawn once, so the ETag names the
 * drawing and a client that has it skips the bytes.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const id = z.string().uuid().safeParse(new URL(request.url).searchParams.get("id"));
    if (!id.success) throw new ApiError(400, "INVALID_QUERY", "id must be a place id");
    const { etag, bytes } = await getPetThemeArt(db, principal.sub, id.data, request.headers.get("if-none-match"));
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/webp" } });
  });
}
