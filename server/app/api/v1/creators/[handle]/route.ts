import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { integerQuery } from "@/lib/http/query";
import { listPacksByCreator } from "@/lib/services/packs";

type Context = { params: Promise<{ handle: string }> };

/** The creator page: their byline plus every pack of theirs the viewer is allowed to see. */
export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { handle } = await context.params;
    const url = new URL(request.url);
    return noStoreJson(await listPacksByCreator(db, principal.sub, handle, {
      limit: integerQuery(url.searchParams.get("limit"), { name: "limit", min: 1, max: 100, defaultValue: 30 }),
      cursor: url.searchParams.get("cursor"),
    }));
  });
}
