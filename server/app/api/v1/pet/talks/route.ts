import { RememberPetTalkRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { rememberPetTalk } from "@/lib/services/pet-memory";

/** Something the owner said to their pet and its answer, for the pet's memory agent to remember. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, RememberPetTalkRequestSchema.parse);
    await rememberPetTalk(db, principal.sub, body);
    return noStoreJson({ accepted: true }, { status: 202 });
  });
}
