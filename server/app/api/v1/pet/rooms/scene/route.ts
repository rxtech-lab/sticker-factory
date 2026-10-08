import { and, eq } from "drizzle-orm";
import { z } from "zod";
import { petRooms } from "@/lib/db/schema";
import { firstRow } from "@/lib/db/client";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, ApiError } from "@/lib/http/errors";
import { SVGSceneSchema } from "@/lib/contracts/controllable";
export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const id = z.string().uuid().safeParse(new URL(request.url).searchParams.get("id"));
    if (!id.success) throw new ApiError(400, "INVALID_QUERY", "A valid scene id is required");
    const row = await db.select({ scene: petRooms.sceneJson, artKey: petRooms.artKey }).from(petRooms)
      .where(and(eq(petRooms.id, id.data), eq(petRooms.userId, principal.sub))).then(firstRow);
    if (!row) throw new ApiError(404, "SCENE_NOT_FOUND", "Scene not found");
    return noStoreJson({ artKey: row.artKey, scene: row.scene ? SVGSceneSchema.parse(row.scene) : null });
  });
}
