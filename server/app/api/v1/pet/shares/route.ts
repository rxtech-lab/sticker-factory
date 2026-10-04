import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { sharePet } from "@/lib/services/pets";

/**
 * The owner is showing their pet to someone in Messages. Answers with the pet to draw on the card;
 * `accepted` says whether this share moved its stats.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => noStoreJson(await sharePet(db, principal.sub)));
}
