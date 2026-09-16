import { buildAssetsReady, completedBuildSteps } from "./build-checkpoints";
import sharp from "sharp";
import { SpriteSheetValidationError } from "@/lib/render/sprite-atlas";
import { eq } from "drizzle-orm";
import type { PlanV1 } from "@/lib/contracts/plan";
import type { StickerConfiguration } from "@/lib/contracts/configuration";
import { getDatabase } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { derivedAssetId, ensureAtlasPoster, getReadyOwnedAssets } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { getObjectStore, objectKey } from "@/lib/storage/r2";
import { generatedLayers, generateAndStoreAsset } from "./asset-generation";
import { assertJobStillRunning, beginToolCall, finishToolCall } from "./turn-context";

function variantAssetId(jobId: string, variantId: string, layerId: string): string {
  return derivedAssetId(jobId, `variant:${variantId}:${layerId}`);
}

export function configurationFromPlan(plan: PlanV1, jobId: string): StickerConfiguration | undefined {
  if (!plan.configuration) return undefined;
  return {
    controls: plan.configuration.controls,
    variants: plan.configuration.variants.map((variant) => ({ ...variant, layers: variant.layers.map((patch) => {
      const source = patch.source;
      if (!source || source.kind === "base" || source.kind === "sequence") return { ...patch, source };
      if (source.kind === "existing") return { ...patch, source: { kind: "image" as const, assetId: source.assetId } };
      const assetId = variantAssetId(jobId, variant.id, patch.layerId);
      if (source.kind === "generate") return { ...patch, source: { kind: "image" as const, assetId } };
      const { prompt: _prompt, kind: _kind, ...grid } = source;
      void _prompt; void _kind;
      return { ...patch, source: { ...grid, kind: "sequence" as const, assetId, posterAssetId: derivedAssetId(assetId, "poster") } };
    }) })),
  };
}

/** Alpha padding catches sheets whose frames bleed across cells before they can become variants. */
export async function validateGeneratedAtlas(bytes: Uint8Array, grid: { columns: number; rows: number; frameCount: number }): Promise<void> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const width = Math.floor(info.width / grid.columns), height = Math.floor(info.height / grid.rows);
  for (let frame = 0; frame < grid.frameCount; frame++) {
    const ox = (frame % grid.columns) * width, oy = Math.floor(frame / grid.columns) * height;
    let visible = 0, border = 0;
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const alpha = data[((oy + y) * info.width + ox + x) * info.channels + info.channels - 1];
      if (alpha > 24) { visible++; if (x === 0 || y === 0 || x === width - 1 || y === height - 1) border++; }
    }
    if (visible < width * height * 0.005) throw new SpriteSheetValidationError("empty", `Generated pose frame ${frame + 1} is empty`);
    if (border > (width + height) * 0.1) throw new SpriteSheetValidationError("clipped", `Generated pose frame ${frame + 1} is clipped at its cell boundary`);
  }
}

export async function generatePlannedVariants(
  job: typeof generationJobs.$inferSelect, stickerId: string, plan: PlanV1, assetJobId: string,
  reference: { bytes: Uint8Array; mimeType: string } | undefined,
): Promise<void> {
  if (!plan.configuration) return;
  const db = await getDatabase();
  const total = plan.configuration.variants.reduce((count, variant) => count + variant.layers.filter(
    (patch) => patch.source?.kind === "generate" || patch.source?.kind === "frames",
  ).length, 0);
  const completedSteps = await completedBuildSteps(job);
  const reused = new Set<string>();
  for (const variant of plan.configuration.variants) for (const patch of variant.layers) {
    const source = patch.source;
    if (!source || (source.kind !== "generate" && source.kind !== "frames")) continue;
    const assetId = variantAssetId(assetJobId, variant.id, patch.layerId);
    const ids = source.kind === "frames" ? [assetId, derivedAssetId(assetId, "poster")] : [assetId];
    if (completedSteps.has(`expression ${variant.id} ${patch.layerId}`) && await buildAssetsReady(job, ids)) reused.add(assetId);
  }
  let completed = reused.size;
  if (completed < total) {
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_variants", message: "Composing expressions and poses…",
      progressLabel: "Expression and pose artwork", completedUnits: completed, totalUnits: total,
    });
  }
  for (const variant of plan.configuration.variants) for (const patch of variant.layers) {
    const source = patch.source;
    if (!source || (source.kind !== "generate" && source.kind !== "frames")) continue;
    if (!reference) throw new Error("Configurable artwork needs the approved static reference");
    await assertJobStillRunning(job.id);
    const assetId = variantAssetId(assetJobId, variant.id, patch.layerId);
    if (reused.has(assetId)) continue;
    const call = await beginToolCall(job, "build-plan", undefined, `expression ${variant.id} ${patch.layerId}`);
    try {
      const layer = plan.layers.find((layer) => layer.layerId === patch.layerId)!;
      const baselineId = layer.source.kind === "existing" ? layer.source.assetId : generatedLayers(plan, assetJobId).find((asset) => asset.layer.layerId === patch.layerId)?.assetId;
      const baselineRow = baselineId ? (await getReadyOwnedAssets(db, job.ownerId, [baselineId]))[0] : undefined;
      const baseline = baselineRow ? await getObjectStore().get(baselineRow.r2Key) : undefined;
      const framing = source.kind === "frames"
        ? `Create a ${source.columns} column by ${source.rows} row sprite sheet. Put exactly ${source.frameCount} animation frames in row-major order. `
          + "Use identical cell sizes, character scale and registration in every cell, matching the isolated layer reference framing. Leave transparent padding on every cell edge. No dividers, labels or text. Trailing unused cells must be transparent. "
          + `Animate only the ${layer.name} layer. All expressions and poses must retain the approved character's identity. `
        : `Draw only the ${layer.name} layer, in exactly the same framing, position and scale as the isolated layer reference. Make every other pixel transparent. `;
      await generateAndStoreAsset(job, stickerId, {
        assetId, references: [reference, ...(baseline ? [{ bytes: baseline.bytes, mimeType: baselineRow!.mimeType }] : [])], mode: "conversation_edit", keepFrame: true,
        prompt: "Use the approved sticker as the exact character reference. Preserve its silhouette, colours, outlines, shading, texture and proportions. "
          + framing + `Selected state: ${JSON.stringify(variant.selections)}. ${source.prompt}`,
        ...(source.kind === "frames" ? { sequence: source } : {}),
      });
      if (source.kind === "frames") {
        const stored = await getObjectStore().get(objectKey(job.ownerId, assetId, "image/png"));
        try { await validateGeneratedAtlas(stored.bytes, source); }
        catch (error) {
          await db.update(assets).set({ state: "failed" }).where(eq(assets.id, assetId));
          throw error;
        }
        const posterId = await ensureAtlasPoster(db, job.ownerId, stickerId, { ...source, assetId });
        if (!posterId) throw new Error("Could not prepare the pose's still preview");
      }
      await finishToolCall(job, call, "complete", { previewAssetId: assetId });
      completed += 1;
      await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
        stage: "composing_variants", message: "Composing expressions and poses…",
        progressLabel: "Expression and pose artwork", completedUnits: completed, totalUnits: total,
      });
    } catch (error) {
      await finishToolCall(job, call, "failed", error);
      throw error;
    }
  }
}
