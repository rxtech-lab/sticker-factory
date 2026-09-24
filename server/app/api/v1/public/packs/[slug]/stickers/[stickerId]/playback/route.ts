import { clientDocumentVersion, downcastForClient } from "@/lib/contracts/sticker";
import { getDatabase } from "@/lib/db/client";
import { errorResponse, noStoreJson } from "@/lib/http/errors";
import { getPublicPackPlayback } from "@/lib/services/public-packs";

export async function GET(request: Request, context: { params: Promise<{ slug: string; stickerId: string }> }) {
  try {
    const { slug, stickerId } = await context.params;
    const bundle = await getPublicPackPlayback(await getDatabase(), slug, stickerId);
    return noStoreJson({ ...bundle, document: downcastForClient(bundle.document, clientDocumentVersion(request)) });
  } catch (error) { return errorResponse(error); }
}
