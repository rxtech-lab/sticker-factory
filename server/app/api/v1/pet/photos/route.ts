import { SendPetPhotoRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { sendPetPhoto } from "@/lib/services/pets";

/** Shows the account's pet a picture it uploaded, and answers with how the pet took it. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SendPetPhotoRequestSchema.parse);
    return noStoreJson(await sendPetPhoto(db, principal.sub, body));
  });
}
