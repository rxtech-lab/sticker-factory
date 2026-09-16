import { and, eq } from "drizzle-orm";
import { planSpriteLayers, type PlanV1 } from "@/lib/contracts/plan";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, generationJobs, plans } from "@/lib/db/schema";
import { derivedAssetId } from "@/lib/services/assets";
import { getObjectStore } from "@/lib/storage/r2";
import { generateAndStoreAsset } from "./asset-generation";

/** Storyboard for approval and motion guidance. The concept stays a resting composition for extraction. */
export async function renderPlanAnimationPreview(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  planId: string,
  revision: number,
  plan: PlanV1,
): Promise<void> {
  const characters = planSpriteLayers(plan);
  if (plan.kind !== "animated" || !plan.configuration || characters.length === 0) return;
  const db = await getDatabase();
  const row = await db.select().from(plans).where(eq(plans.id, planId)).then(firstRow);
  const concept = row?.conceptAssetId && await db.select().from(assets).where(and(
    eq(assets.id, row.conceptAssetId), eq(assets.ownerId, job.ownerId),
    eq(assets.stickerId, stickerId), eq(assets.state, "ready"),
  )).then(firstRow);
  if (!concept) throw new Error("Animation overview requires the plan's resting reference");
  const prompt = [
    "Create a polished illustrated animation-plan summary board on a light background.",
    "The attached image defines the exact character designs, colours, style and composition. Preserve them.",
    "Show a large resting-composition hero, then clearly separated labelled panels showing what the planned motions and expressions will look like.",
    "Use a few representative start / middle / end poses and subtle arrows to explain motion; show the face expression choices alongside them.",
    "This is a visual storyboard for approval, not a playable animation or a sprite atlas. No cut-apart body parts or face slots.",
    "Use the plan title and short readable labels in the language of the plan. Keep text sparse and legible. Do not invent controls, motions or expressions.",
    "When there are many choices, illustrate representative examples and list the remaining labels compactly. Do not draw every combination.",
    `Title: ${plan.title}. Summary: ${plan.summary}`,
    `Timing: ${plan.timing.durationSeconds} seconds, ${plan.timing.loop}.`,
    ...characters.map(({ layer, source }) => JSON.stringify({
      character: layer.name,
      motions: source.clips.map((clip) => ({ label: clip.label, motion: clip.prompt })),
      expressions: source.expressions.map((expression) => ({ label: expression.label, appearance: expression.prompt })),
    })),
    `Available controls: ${JSON.stringify(plan.configuration.controls)}`,
  ].join("\n");
  // Keyed on everything the board is drawn from — its own prompt and the reference it redraws the
  // characters out of — rather than on the revision, so a redraft that changes neither reuses the
  // storyboard instead of buying a second copy of the same picture. See `renderPlanConcept`.
  const assetId = derivedAssetId(planId, `animation-preview:${concept.id}:${prompt}`);
  if (row?.animationPreviewAssetId === assetId) return;
  const reference = await getObjectStore().get(concept.r2Key);
  await generateAndStoreAsset(job, stickerId, {
    assetId, prompt, references: [{ bytes: reference.bytes, mimeType: concept.mimeType }],
    mode: "generate", concept: true, conceptPurpose: "animation-summary",
  });
  await db.update(plans).set({ animationPreviewAssetId: assetId, updatedAt: new Date() })
    .where(and(eq(plans.id, planId), eq(plans.revision, revision)));
}
