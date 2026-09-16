import { compileLayerAnimation, countKeyframes } from "@/lib/animation/compile";
import { configurationIssues, updateConfiguration, type PlanConfiguration } from "./configuration";
import { compilePlanAnimations, planLayerAnchor, type PlanV1 } from "./plan";
import { StickerDocumentSchema, type StickerDocument } from "./sticker";

/** Convert only the source vocabulary; original runtime layers are never replanned. */
export function extensionConfiguration(plan: PlanV1, base: StickerDocument): PlanConfiguration | undefined {
  const configuration: PlanConfiguration | undefined = base.configuration && {
    controls: base.configuration.controls,
    variants: base.configuration.variants.map((variant) => ({ ...variant, layers: variant.layers.map((patch) => ({
      ...patch, source: patch.source?.kind === "image" ? { kind: "existing", assetId: patch.source.assetId } : patch.source,
    })) })),
  };
  return updateConfiguration(configuration, plan.configurationChanges ?? {});
}

/** Validate the merged surface before buying any new artwork. The actual assembly validates the
 * registered sheets as well; here the plan's declared clip and expression ids are authoritative. */
export function validateExtensionPlan(plan: PlanV1, base: StickerDocument): void {
  if (!plan.baseRevisionId) throw new Error("Missing extension base revision");
  StickerDocumentSchema.parse(base);
  if (plan.kind !== base.kind) throw new Error("An extension cannot change the sticker kind");
  const existing = new Map(base.layers.map((layer) => [layer.id, layer]));
  const additions = new Map(plan.layers.map((layer) => [layer.layerId, layer]));
  const ids = new Set([...existing.keys(), ...additions.keys()]);
  if (ids.size > 12) throw new Error("The combined plan can contain at most 12 layers");
  const configuration = extensionConfiguration(plan, base);
  const issues = configuration ? configurationIssues(configuration, ids) : [];
  if (configuration && plan.kind !== "animated") issues.push("Configurable stickers need an animated plan");
  const timing = { kind: plan.kind, durationSeconds: Math.max(base.durationSeconds, plan.timing.durationSeconds) };
  const compiled = compilePlanAnimations(plan);
  const heaviest = new Map([...ids].map((id) => [id, additions.has(id)
    ? countKeyframes(compiled[plan.layers.findIndex((layer) => layer.layerId === id)])
    : countKeyframes(existing.get(id)!.animation)]));
  let videos = 0;
  for (const id of ids) {
    const planned = additions.get(id)?.source;
    if ((planned?.kind ?? existing.get(id)?.type) === "video") videos++;
  }
  if (videos > 1) issues.push("The combined sticker can contain only one video layer");
  for (const variant of configuration?.variants ?? []) for (const patch of variant.layers) {
    const planned = additions.get(patch.layerId);
    const retained = existing.get(patch.layerId);
    const source = planned?.source;
    const type = source?.kind ?? retained?.type;
    if (patch.text !== undefined && (type !== "text" || (patch.source && patch.source.kind !== "base"))) {
      issues.push(`Caption binding needs a text layer: ${patch.layerId}`);
    }
    if (type === "sprite") {
      const sprite = source?.kind === "sprite" ? source : retained?.type === "sprite" ? retained : undefined;
      const expressions = sprite && (Array.isArray(sprite.expressions) ? sprite.expressions : sprite.expressions.tiles);
      if (patch.source) issues.push(`Preserve sprite ${patch.layerId}; select its clip or expression instead of replacing its source`);
      if (patch.clip !== undefined && !sprite?.clips.some((clip) => clip.id === patch.clip)) issues.push(`Unknown clip ${patch.clip}`);
      if (patch.expression !== undefined && !expressions?.some((expression) => expression.id === patch.expression)) issues.push(`Unknown expression ${patch.expression}`);
    } else if (patch.clip !== undefined || patch.expression !== undefined) {
      issues.push(`Layer ${patch.layerId} is not a sprite`);
    }
    if (patch.animations && (planned || retained)) {
      try {
        const animation = compileLayerAnimation(patch.animations, planned ? planLayerAnchor(planned) : retained!.anchor, timing);
        heaviest.set(patch.layerId, Math.max(heaviest.get(patch.layerId) ?? 0, countKeyframes(animation)));
      } catch (error) { issues.push((error as Error).message); }
    }
  }
  if ([...heaviest.values()].reduce((sum, count) => sum + count, 0) > 128) issues.push("Combined controls exceed the 128 keyframe budget");
  if (issues.length) throw new Error(issues.join("; "));
}
