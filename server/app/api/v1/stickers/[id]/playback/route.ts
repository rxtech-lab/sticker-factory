import { clientDocumentVersion, downcastForClient } from "@/lib/contracts/sticker";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { getStickerPlayback } from "@/lib/services/playback";

export async function GET(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const bundle = await getStickerPlayback(db, principal.sub, id, new URL(request.url).searchParams.get("revisionId") ?? undefined);
    return noStoreJson({ ...bundle, document: downcastForClient(bundle.document, clientDocumentVersion(request)) });
  });
}
