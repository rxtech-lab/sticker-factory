import { after } from "next/server";
import { SharePetContentRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { acceptPetContentShare } from "@/lib/services/pets";

/** Accepts a share; the pet reads it after the share sheet closes. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SharePetContentRequestSchema.parse);
    return noStoreJson(await acceptPetContentShare(db, principal.sub, body, (task) => after(task)), { status: 202 });
  });
}
