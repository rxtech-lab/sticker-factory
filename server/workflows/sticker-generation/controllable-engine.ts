import type { PlanV1 } from "@/lib/contracts/plan";
import { planSpriteLayers, assertControllablePlan, planSpriteSheetCount } from "@/lib/contracts/plan";
import { SVGAnimationRigSchema, type ControllableEngineID } from "@/lib/contracts/controllable";
import { traceEvent } from "@/lib/observability/trace";
import { z } from "zod";
import { FatalError } from "workflow";
import { authorSVG, SVGArtworkValidationError } from "@/lib/ai/gateway-svg";
import type { AiReferenceImage } from "@/lib/ai/gateway-contracts";
import type { GenerationJobRow } from "@/lib/db/schema";
import { generatedLayers, type SpriteBuild } from "./asset-generation";
import { generateSpriteArtwork } from "./sprite-artwork";
import { loadBuildCheckpoint, saveBuildCheckpoint } from "./build-checkpoints";
import { svgProgressReporter } from "./svg-progress";
import { getDatabase } from "@/lib/db/client";
import { appendGenerationEvent } from "@/lib/services/events";

export interface ControllableGenerationInput {
  job: GenerationJobRow; stickerId: string; plan: PlanV1; assetJobId: string;
  reference: AiReferenceImage | undefined; summary: AiReferenceImage | undefined; stayPut: boolean;
}
export interface ControllableEngine {
  readonly id: ControllableEngineID;
  planningGuidance: string;
  validate(plan: PlanV1): void;
  estimate(plan: PlanV1): { images: number; vectorCalls: number };
  generate(input: ControllableGenerationInput): Promise<Map<string, SpriteBuild>>;
}
export class LegacyControllableEngine implements ControllableEngine {
  readonly id = "legacy" as const;
  planningGuidance = "Plan body clips and face expressions as sprite sheets.";
  validate = assertControllablePlan;
  estimate(plan: PlanV1) { return { images: planSpriteSheetCount({ ...plan, engine: "legacy" }), vectorCalls: 0 }; }
  generate(i: ControllableGenerationInput) { return generateSpriteArtwork(i.job, i.stickerId, i.plan, i.assetJobId, i.reference, i.summary, { stayPut: i.stayPut }); }
}
export class SVGControllableEngine implements ControllableEngine {
  readonly id = "svg" as const;
  planningGuidance = "Plan named poses and expressions; the approved image will become animated SVG groups, not sprite sheets.";
  validate = assertControllablePlan;
  estimate(plan: PlanV1) { return { images: 0, vectorCalls: planSpriteLayers(plan).length * 2 }; }
  async generate(i: ControllableGenerationInput) {
    const builds = new Map<string, SpriteBuild>();
    const started = Date.now();
    const db = await getDatabase();
    const total = planSpriteLayers(i.plan).length;
    if (total) await appendGenerationEvent(db, i.job.id, i.job.ownerId, "progress", {
      stage: "authoring_svg", message: "Preparing SVG animation…", progressLabel: "SVG characters", completedUnits: 0, totalUnits: total,
    });
    traceEvent("controllable:generating", { engine: this.id, jobId: i.job.id, ...this.estimate(i.plan) });
    for (const { layer, source } of planSpriteLayers(i.plan)) {
      if (!i.reference) throw new Error("SVG generation requires the approved reference image");
      const key = `svg:${layer.layerId}`;
      let rig = await loadBuildCheckpoint(i.job, i.assetJobId, key, SVGAnimationRigSchema);
      traceEvent("controllable:checkpoint", { engine: this.id, jobId: i.job.id, layerId: layer.layerId, reused: !!rig });
      if (!rig) {
        rig = SVGAnimationRigSchema.parse(await authorSVG({ reference: i.reference, scene: false, onProgress: svgProgressReporter(i.job, layer), requiredStates: { pose: [...new Set(["idle", "walk", ...source.clips.map(c => c.id)])], expression: source.expressions.map(e => e.id) },
          brief: `Draw this character from the reference, no background; props from the reference are separate groups shown only in poses that use them: ${source.prompt}. Requested pose ids and motions: ${JSON.stringify(source.clips)}. Requested expression ids: ${JSON.stringify(source.expressions)}. Default pose=${source.clips[0].id}, expression=${source.expressions[0].id}. ${i.stayPut ? "Stay on a fixed ground line." : "Allow expressive motion."}` })
          // authorSVG already spent its bounded repair attempts; a step retry would just buy three more.
          .catch(error => { throw error instanceof SVGArtworkValidationError || error instanceof z.ZodError ? new FatalError(error.message) : error; }));
        // Do not accept a rig that silently omits an approved control choice.
        for (const [key, ids] of [["pose", source.clips.map(c => c.id)], ["expression", source.expressions.map(e => e.id)]] as const) {
          for (const id of ids) if (!rig.groups.some(g => g.when[key]?.includes(id))) throw new Error(`SVG is missing ${key} ${id}`);
        }
        await saveBuildCheckpoint(i.job, i.assetJobId, key, rig);
      }
      const still = generatedLayers(i.plan, i.assetJobId).find(item => item.layer.layerId === layer.layerId);
      if (!still) throw new Error("SVG character has no retained reference poster");
      builds.set(layer.layerId, { rig, clips: [], expressions: { assetId: still.assetId, columns: 1, rows: 1, tiles: [] }, posterAssetId: still.assetId });
      await appendGenerationEvent(db, i.job.id, i.job.ownerId, "progress", {
        stage: "authoring_svg", message: "SVG animation ready", note: `${layer.name} is ready.`,
        progressLabel: "SVG characters", completedUnits: builds.size, totalUnits: total, engine: this.id,
      });
    }
    traceEvent("controllable:complete", { engine: this.id, jobId: i.job.id, durationMs: Date.now() - started });
    return builds;
  }
}
export function controllableEngine(id: ControllableEngineID): ControllableEngine {
  return id === "svg" ? new SVGControllableEngine() : new LegacyControllableEngine();
}
