import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { getStickerPlayback } from "@/lib/services/playback";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    return noStoreJson(await getStickerPlayback(db, principal.sub, id, new URL(request.url).searchParams.get("revisionId") ?? undefined));
  });
}
