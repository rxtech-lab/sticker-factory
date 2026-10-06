import { after } from "next/server";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetThemes, refreshPetThemes } from "@/lib/services/pet-themes";

// Discovering places designs and draws them after the response.
export const maxDuration = 300;

/**
 * The places the pet knows and the one it is at. When it is due new ones — a trip, an accident, or
 * a new day — its agent starts looking after the response; `discovering` says so, and a later read
 * carries them.
 */
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    after(() => refreshPetThemes(db, principal.sub));
    return noStoreJson({ themes: await listPetThemes(db, principal.sub) });
  });
}
