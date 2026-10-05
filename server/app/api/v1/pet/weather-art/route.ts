import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { getPetWeatherArt, PET_WEATHER_ART_MAX_SIZE, PET_WEATHER_ART_MIN_SIZE } from "@/lib/services/pet-weather";

/**
 * The weather the caller's pet is in, drawn in the pet's own style, as a transparent PNG — what the
 * Pet tab stands behind the pet and the widget shows beside it. 404 until it has been drawn.
 *
 * Revalidated like the pose: the ETag names the drawing and size, so a client that has it skips the bytes.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const url = new URL(request.url);
    const size = integerQuery(url.searchParams.get("size"), {
      name: "size", min: PET_WEATHER_ART_MIN_SIZE, max: PET_WEATHER_ART_MAX_SIZE, defaultValue: 256,
    })!;
    const { etag, bytes } = await getPetWeatherArt(
      db, principal.sub, size, request.headers.get("if-none-match"), url.searchParams.get("artKey"),
    );
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/png" } });
  });
}
