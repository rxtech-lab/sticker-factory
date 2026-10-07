import { PetTouchRequestSchema } from "@/lib/contracts/pet-touch";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { decidePetTouchPose } from "@/lib/services/pet-touch";

/** A touch on the phone, answered with the pose the pet strikes for a moment, decided by its decision model. */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, PetTouchRequestSchema.parse);
    return noStoreJson(await decidePetTouchPose(db, principal.sub, body.touch, body.pose));
  });
}
