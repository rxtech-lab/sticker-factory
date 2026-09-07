import { getDatabase } from "@/lib/db/client";
import { errorResponse, noStoreJson } from "@/lib/http/errors";
import { getPublicPack } from "@/lib/services/public-packs";
export async function GET(_request: Request, context: { params: Promise<{ slug: string }> }) {
  try { return noStoreJson(await getPublicPack(await getDatabase(), (await context.params).slug)); }
  catch (error) { return errorResponse(error); }
}
