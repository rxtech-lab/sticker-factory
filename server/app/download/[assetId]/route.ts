import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { createAssetDownload } from "@/lib/services/assets";

type Context = { params: Promise<{ assetId: string }> };
export async function GET(request: Request, context: Context) {
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) return Response.redirect(new URL("/login", request.url));
  const { assetId } = await context.params;
  const download = await createAssetDownload(getDatabase(), ownerId, assetId);
  return Response.redirect(download.url, 307);
}
