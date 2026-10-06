import { SetPetThemeRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPetThemes, setPetTheme } from "@/lib/services/pet-themes";
import { getPet } from "@/lib/services/pets";

/**
 * Takes the pet to a place it knows, or home with null. Refused when the place's rules do not allow
 * it right now, and for good once a limited place has expired. Repeating it changes nothing.
 */
export async function PUT(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, SetPetThemeRequestSchema.parse);
    await setPetTheme(db, principal.sub, body.themeId);
    return noStoreJson({ pet: (await getPet(db, principal.sub)).pet, themes: await listPetThemes(db, principal.sub) });
  });
}
