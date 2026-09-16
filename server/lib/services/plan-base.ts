import { and, eq } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { stickerRevisions, stickers } from "@/lib/db/schema";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { validateExtensionPlan } from "@/lib/contracts/plan-extension";
import { assertPlanReuseIsResolvable, type PlanV1 } from "@/lib/contracts/plan";
import { ApiError } from "@/lib/http/errors";

/** Used at draft, confirmation and build: never substitute the latest revision on a retry. */
export async function loadPlanBase(db: Database, ownerId: string, stickerId: string, plan: PlanV1) {
  if (!plan.baseRevisionId) return undefined;
  const result = await db.select({ revision: stickerRevisions }).from(stickerRevisions).innerJoin(stickers, eq(stickers.id, stickerRevisions.stickerId)).where(and(
    eq(stickerRevisions.id, plan.baseRevisionId), eq(stickers.ownerId, ownerId), eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  const row = result?.revision;
  if (!row || row.candidateState === "rejected" || row.candidateState === "superseded") {
    throw new ApiError(409, "PLAN_BASE_CHANGED", "This plan's original revision is no longer available. Request a revised plan.");
  }
  const document = StickerDocumentSchema.parse(row.documentJson);
  validateExtensionPlan(plan, document);
  assertPlanReuseIsResolvable(plan, document);
  return { ...row, document };
}
