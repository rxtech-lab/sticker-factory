import sharp from "sharp";
import { eq } from "drizzle-orm";
import { loadPlanBase } from "@/lib/services/plan-base";
import { derivedAssetId, getReadyOwnedAssets } from "@/lib/services/assets";
import { attachPlanConcept } from "@/lib/services/plans";
import { plannedConfiguration, type PlanV1 } from "@/lib/contracts/plan";
import { resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { getDatabase, firstRow } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { referencedAssetIds } from "@/lib/render/sticker-render";
import { renderStillPng } from "@/lib/render/renditions";
import type { RenderAssets } from "@/lib/render/document-svg";
import { documentFromPlan, generateAndStoreAsset } from "./asset-generation";
import { assertJobStillRunning } from "./turn-context";

/** Preserve base pixels in the approval image. The model draws only transparent additions;
 * compositing them is deterministic, and retries reuse both the sketch and the finished preview. */
export async function renderExtensionPreview(
  job: typeof generationJobs.$inferSelect, stickerId: string, planId: string, plan: PlanV1,
  references: Array<{ bytes: Uint8Array; mimeType: string }>,
): Promise<void> {
  const db = await getDatabase(), store = getObjectStore();
  const base = await loadPlanBase(db, job.ownerId, stickerId, plan);
  if (!base) throw new Error("Missing extension base");
  const changes = JSON.stringify({ base: base.id, layers: plan.layers, changes: plan.configurationChanges, prompt: plan.conceptPrompt });
  const previewId = derivedAssetId(planId, `extension-preview:${changes}`);
  const existing = await db.select().from(assets).where(eq(assets.id, previewId)).then(firstRow);
  if (existing?.state === "ready") {
    await attachPlanConcept(db, planId, previewId);
    return;
  }
  const selectedVariant = plannedConfiguration(plan)?.variants.find((variant) => variant.layers.some((patch) => patch.source?.kind === "generate" || patch.source?.kind === "frames"));
  const newArtwork = plan.layers.filter((layer) => ["generate", "sprite", "video"].includes(layer.source.kind));
  const native = plan.layers.filter((layer) => !newArtwork.includes(layer));
  const previewPlan = { ...plan, layers: native, configurationChanges: undefined };
  const document = resolveStickerConfiguration(documentFromPlan(previewPlan, job.id, undefined, undefined, base.document));
  // Explicit replacements must not appear twice in the approval composition.
  const changedIds = new Set([...newArtwork.map((layer) => layer.layerId), ...(selectedVariant?.layers.filter((patch) => patch.source?.kind === "generate" || patch.source?.kind === "frames").map((patch) => patch.layerId) ?? [])]);
  document.layers = document.layers.filter((layer) => !changedIds.has(layer.id));
  const loaded: RenderAssets = new Map();
  const ids = referencedAssetIds(document);
  const rows = await getReadyOwnedAssets(db, job.ownerId, ids);
  if (rows.length !== ids.length) throw new Error("The existing artwork is unavailable for preview");
  for (const row of rows) {
    const object = await store.get(row.r2Key);
    loaded.set(row.id, { bytes: object.bytes, mimeType: row.mimeType });
  }
  const retained = await renderStillPng(document, loaded, 1024);
  let bytes: Uint8Array = retained;
  if (newArtwork.length || selectedVariant) {
    const sketchId = derivedAssetId(planId, `extension-sketch:${changes}`);
    await generateAndStoreAsset(job, stickerId, {
      assetId: sketchId, concept: true, conceptPurpose: "extension", mode: "generate",
      references: [{ bytes: retained, mimeType: "image/png" }, ...references].slice(0, 4),
      prompt: `Proposed additions to ${plan.title}. ${plan.summary}. ${plan.conceptPrompt ?? ""}\n`
        + `Draw only these additions at their normalized positions, using their scale relative to 86% of the canvas: ${JSON.stringify(newArtwork)}.\n`
        + `For new illustrated variants, show one representative new option in its layer's position: ${JSON.stringify(selectedVariant ?? {})}.\n`
        + `Existing layer positions for variant-only additions: ${JSON.stringify(base.document.layers.map((layer) => ({ id: layer.id, name: layer.name, anchor: layer.anchor })))}.\n`
        + "Do not copy existing characters from the reference. Their pixels will be composited separately.",
    });
    const sketch = await store.get(objectKey(job.ownerId, sketchId, "image/png"));
    const inspection = await inspectImage(sketch.bytes);
    if (!inspection.hasTransparentPixels) throw new Error("The additions preview must have a transparent background");
    bytes = await sharp(retained).composite([{ input: Buffer.from(sketch.bytes) }]).png().toBuffer();
  }
  const image = await inspectImage(bytes);
  const key = objectKey(job.ownerId, previewId, "image/png");
  await assertJobStillRunning(job.id);
  await store.put(key, { bytes, contentType: "image/png", metadata: { sha256: image.sha256 } });
  await db.insert(assets).values({
    id: previewId, ownerId: job.ownerId, stickerId, kind: "preview", state: "ready", r2Key: key,
    mimeType: "image/png", byteSize: image.byteSize, width: image.width, height: image.height,
    sha256: image.sha256, hasAlpha: image.hasTransparentPixels, createdAt: new Date(), readyAt: new Date(),
  }).onConflictDoNothing();
  await attachPlanConcept(db, planId, previewId);
}
