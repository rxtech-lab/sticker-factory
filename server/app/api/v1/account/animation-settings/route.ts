import { z } from "zod";
import { ControllableEngineSchema } from "@/lib/contracts/controllable";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { animationSettings, setAnimationSettings } from "@/lib/services/animation-settings";
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => noStoreJson(await animationSettings(db, principal.sub)));
}
export async function PATCH(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const input = await readJson(request, z.object({ engine: ControllableEngineSchema }).strict().parse);
    return noStoreJson(await setAnimationSettings(db, principal.sub, input.engine));
  });
}
