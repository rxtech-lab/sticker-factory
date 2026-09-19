import { buildAssetsReady, completedBuildSteps } from "./build-checkpoints";
import { eq } from "drizzle-orm";
import { plannedConfiguration, type PlanV1 } from "@/lib/contracts/plan";
import { updateConfiguration, type StickerConfiguration } from "@/lib/contracts/configuration";
import { getDatabase } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { derivedAssetId, ensureAtlasPoster, getReadyOwnedAssets } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { generatedLayers, generateAndStoreAsset } from "./asset-generation";
import { drawSheet, prepareSheet } from "./sheet-drawing";
import { assertJobStillRunning, beginToolCall, finishToolCall } from "./turn-context";

function variantAssetId(jobId: string, variantId: string, layerId: string): string {
  return derivedAssetId(jobId, `variant:${variantId}:${layerId}`);
}

export function configurationFromPlan(plan: PlanV1, jobId: string, base?: StickerConfiguration): StickerConfiguration | undefined {
  const configuration = plannedConfiguration(plan);
  if (!configuration) return base;
  const converted: StickerConfiguration = {
    controls: configuration.controls,
    variants: configuration.variants.map((variant) => ({ ...variant, layers: variant.layers.map((patch) => {
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
  return plan.baseRevisionId ? updateConfiguration(base, {
    ...plan.configurationChanges, upsertControls: converted.controls, upsertVariants: converted.variants,
  }) : converted;
}

export async function generatePlannedVariants(
  job: typeof generationJobs.$inferSelect, stickerId: string, plan: PlanV1, assetJobId: string,
  reference: { bytes: Uint8Array; mimeType: string } | undefined,
  base?: import("@/lib/contracts/sticker").StickerDocument,
): Promise<void> {
  const configuration = plannedConfiguration(plan);
  if (!configuration) return;
  const db = await getDatabase();
  const total = configuration.variants.reduce((count, variant) => count + variant.layers.filter(
    (patch) => patch.source?.kind === "generate" || patch.source?.kind === "frames",
  ).length, 0);
  const completedSteps = await completedBuildSteps(job);
  const reused = new Set<string>();
  for (const variant of configuration.variants) for (const patch of variant.layers) {
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
  for (const variant of configuration.variants) for (const patch of variant.layers) {
    const source = patch.source;
    if (!source || (source.kind !== "generate" && source.kind !== "frames")) continue;
    if (!reference) throw new Error("Configurable artwork needs the approved static reference");
    await assertJobStillRunning(job.id);
    const assetId = variantAssetId(assetJobId, variant.id, patch.layerId);
    if (reused.has(assetId)) continue;
    const call = await beginToolCall(job, "build-plan", undefined, `expression ${variant.id} ${patch.layerId}`);
    try {
      const layer = plan.layers.find((layer) => layer.layerId === patch.layerId);
      const retained = base?.layers.find((layer) => layer.id === patch.layerId);
      const baselineId = layer?.source.kind === "existing" ? layer.source.assetId : generatedLayers(plan, assetJobId).find((asset) => asset.layer.layerId === patch.layerId)?.assetId ?? (retained?.type === "image" ? retained.assetId : undefined);
      const baselineRow = baselineId ? (await getReadyOwnedAssets(db, job.ownerId, [baselineId]))[0] : undefined;
      const baseline = baselineRow ? await getObjectStore().get(baselineRow.r2Key) : undefined;
      const name = layer?.name ?? retained?.name ?? patch.layerId;
      const references = [reference, ...(baseline ? [{ bytes: baseline.bytes, mimeType: baselineRow!.mimeType }] : [])];
      // The grid, the cell margins and the transparent trailing cells are `sheetInstruction`'s to
      // state, and it is given the sheet below. Repeating them here only risks contradicting it.
      const framing = source.kind === "frames"
        ? `Animate only the ${name} layer, in the same framing and at the same scale as the isolated layer reference. All poses and expressions must retain the approved character's identity. `
        : `Draw only the ${name} layer, in exactly the same framing, position and scale as the isolated layer reference. Make every other pixel transparent. `;
      const prompt = (feedback?: string[]) =>
        "Use the approved sticker as the exact character reference. Preserve its silhouette, colours, outlines, shading, texture and proportions. "
        + framing + `Selected state: ${JSON.stringify(variant.selections)}. ${source.prompt}`
        + (feedback?.length ? ` A previous attempt was rejected: ${feedback.join("; ")}. Fix every listed problem in this drawing.` : "");
      if (source.kind !== "frames") {
        await generateAndStoreAsset(job, stickerId, {
          assetId, references, mode: "conversation_edit", keepFrame: true, prompt: prompt(),
        });
      } else {
        // A pose sheet gets the same treatment as a sprite's: repaired when the drawings are intact
        // but drifted, redrawn with the specific complaint when they are not. Before this it had
        // neither, so one overshooting wing failed the whole turn — and failed it again on every
        // replay, because nothing about the request had changed.
        const { prepared, recoveredSavedSheet } = await drawSheet({
          job, stickerId, assetId,
          generate: (feedback) => generateAndStoreAsset(job, stickerId, {
            assetId, references, mode: "conversation_edit", keepFrame: true,
            sheet: { columns: source.columns, rows: source.rows, count: source.frameCount },
            sequence: source, prompt: prompt(feedback),
          }),
          prepare: (bytes) => prepareSheet(bytes, source, async () => undefined),
          note: () => "Correcting the frame layout and redrawing the poses",
        });
        if (prepared.repaired || recoveredSavedSheet) {
          const inspection = await inspectImage(prepared.bytes);
          const r2Key = objectKey(job.ownerId, assetId, "image/png");
          await getObjectStore().put(r2Key, { bytes: prepared.bytes, contentType: "image/png", metadata: { sha256: inspection.sha256 } });
          await db.update(assets).set({
            state: "ready", byteSize: inspection.byteSize, sha256: inspection.sha256,
            hasAlpha: inspection.hasTransparentPixels, readyAt: new Date(),
          }).where(eq(assets.id, assetId));
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
