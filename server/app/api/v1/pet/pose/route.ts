import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { getPetPose, PET_POSE_MAX_SIZE, PET_POSE_MIN_SIZE } from "@/lib/services/pets";

/**
 * The caller's pet in its current pose, as a transparent PNG — what the widget and the watch show.
 *
 * Private and revalidated rather than stored: the pose changes whenever the pet reads a send, and
 * the ETag lets a client that already has this exact still skip the render and the bytes.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const url = new URL(request.url);
    const size = integerQuery(url.searchParams.get("size"), {
      name: "size", min: PET_POSE_MIN_SIZE, max: PET_POSE_MAX_SIZE, defaultValue: 256,
    })!;
    const { etag, bytes } = await getPetPose(db, principal.sub, size, request.headers.get("if-none-match"));
    const headers = { etag, "cache-control": "private, no-cache" };
    if (!bytes) return new Response(null, { status: 304, headers });
    return new Response(Buffer.from(bytes), { headers: { ...headers, "content-type": "image/png" } });
  });
}
