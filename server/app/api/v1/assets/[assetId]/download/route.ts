import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { createAssetDownload } from "@/lib/services/assets";

type Context = { params: Promise<{ assetId: string }> };
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { assetId } = await context.params;
    return noStoreJson(await createAssetDownload(db, principal.sub, assetId));
  });
}
