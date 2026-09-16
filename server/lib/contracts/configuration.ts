import { z } from "zod";
import { AnimationSpecV1Schema } from "./animation";

const ID = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/);
const Label = z.string().trim().min(1).max(80);
export const StickerControlSchema = z.discriminatedUnion("type", [
  z.object({ id: ID, label: Label, type: z.literal("choice"), defaultValue: ID,
    options: z.array(z.object({ id: ID, label: Label }).strict()).min(2).max(8) }).strict(),
  z.object({ id: ID, label: Label, type: z.literal("number"), binding: z.literal("speed"),
    defaultValue: z.number().min(0.25).max(2), minimum: z.number().min(0.25).max(2),
    maximum: z.number().min(0.25).max(2), step: z.number().min(0.01).max(1) }).strict(),
  z.object({ id: ID, label: Label, type: z.literal("toggle"), defaultValue: z.boolean(),
    layerIds: z.array(ID).min(1).max(32) }).strict(),
]);

export const RuntimeVariantSourceSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("base") }).strict(),
  z.object({ kind: z.literal("image"), assetId: z.string().uuid() }).strict(),
  z.object({ kind: z.literal("sequence"), assetId: z.string().uuid(),
    columns: z.number().int().min(1).max(8), rows: z.number().int().min(1).max(8),
    frameCount: z.number().int().min(1).max(64), frameRate: z.number().min(1).max(60),
    playback: z.enum(["loop", "once", "pingPong"]), posterAssetId: z.string().uuid().optional(),
  }).strict(),
]);

export const PlannedVariantSourceSchema = z.discriminatedUnion("kind", [
  RuntimeVariantSourceSchema.options[2],
  z.object({ kind: z.literal("base") }).strict(),
  z.object({ kind: z.literal("generate"), prompt: z.string().trim().min(1).max(2000) }).strict(),
  z.object({ kind: z.literal("existing"), assetId: z.string().uuid() }).strict(),
  z.object({ kind: z.literal("frames"), prompt: z.string().trim().min(1).max(2000),
    columns: z.number().int().min(1).max(8), rows: z.number().int().min(1).max(8),
    frameCount: z.number().int().min(2).max(64), frameRate: z.number().min(1).max(30),
    playback: z.enum(["loop", "once", "pingPong"]).default("loop"),
  }).strict(),
]);

function configurationSchema<T extends z.ZodType>(source: T) {
  return z.object({
    // Sixteen rather than eight: a cast of four characters needs a pose and a mood each before it
    // has spent anything on speed or on hiding an accessory.
    controls: z.array(StickerControlSchema).min(1).max(16),
    variants: z.array(z.object({
      id: ID,
      selections: z.record(ID, ID),
      layers: z.array(z.object({ layerId: ID, source: source.optional(),
        animations: z.array(AnimationSpecV1Schema).max(12).optional(),
        /** For a sprite layer: which body clip plays. A pose control binds this. */
        clip: ID.optional(),
        /** For a sprite layer: which face is drawn into every frame's slot. A mood control binds this. */
        expression: ID.optional(),
        text: z.string().min(1).max(160).optional(),
        hidden: z.boolean().optional(),
      }).strict()).min(1).max(32),
      // A hundred and twenty-eight, to stay reachable at the control ceiling: sixteen controls at
      // eight options each is exactly that many rows, and eight characters with four moods and four
      // poses apiece is sixty-four. At 64 the raised control cap would be unusable at its top end.
    }).strict()).max(128),
  }).strict();
}

export const StickerConfigurationSchema = configurationSchema(RuntimeVariantSourceSchema);
export const PlanConfigurationSchema = configurationSchema(PlannedVariantSourceSchema);
function changesSchema<T extends z.ZodType>(configuration: ReturnType<typeof configurationSchema<T>>) {
  return z.object({
    upsertControls: z.array(StickerControlSchema).max(16).optional(),
    removeControlIds: z.array(ID).max(16).optional(),
    upsertVariants: configuration.shape.variants.optional(),
    removeVariantIds: z.array(ID).max(128).optional(),
  }).strict();
}
export const ConfigurationChangesSchema = changesSchema(StickerConfigurationSchema);
export const PlanConfigurationChangesSchema = changesSchema(PlanConfigurationSchema);
export type ConfigurationChanges = z.infer<typeof ConfigurationChangesSchema>;
export type PlanConfigurationChanges = z.infer<typeof PlanConfigurationChangesSchema>;
export type StickerControl = z.infer<typeof StickerControlSchema>;
export type StickerConfiguration = z.infer<typeof StickerConfigurationSchema>;
export type PlanConfiguration = z.infer<typeof PlanConfigurationSchema>;
export type StickerControlValues = Record<string, string | number | boolean>;

type Configuration = StickerConfiguration | PlanConfiguration;

/** Upserts replace one definition, never the surrounding configuration. Validation is deferred
 * until layers and bindings have landed together. Removed choices also remove their variant rows. */
export function updateConfiguration<T extends Configuration>(
  configuration: T | undefined,
  changes: { upsertControls?: StickerControl[]; removeControlIds?: string[]; upsertVariants?: T["variants"]; removeVariantIds?: string[] },
): T | undefined {
  const merge = <V extends { id: string }>(current: V[], upserts: V[], removed: string[]) => {
    if (new Set(upserts.map((value) => value.id)).size !== upserts.length) throw new Error("Duplicate upsert ids");
    if (upserts.some((value) => removed.includes(value.id))) throw new Error("Cannot remove and upsert the same id");
    const result = new Map(current.filter((value) => !removed.includes(value.id)).map((value) => [value.id, value]));
    for (const value of upserts) result.set(value.id, value);
    return [...result.values()];
  };
  const removed = changes.removeControlIds ?? [];
  const controls = merge(configuration?.controls ?? [], changes.upsertControls ?? [], removed);
  const variants = merge<T["variants"][number]>(configuration?.variants ?? [], changes.upsertVariants ?? [], changes.removeVariantIds ?? [])
    .filter((variant) => !removed.some((id) => id in variant.selections));
  if (!controls.length && !variants.length) return undefined;
  return { controls, variants } as T;
}

export function requiresConfigurationV6(configuration?: Configuration): boolean {
  return configuration?.variants.some((variant) => variant.layers.some((layer) => layer.text !== undefined || layer.hidden !== undefined)) ?? false;
}

/** States one configurable layer can be prepared in — the old whole-sticker cap, now per character. */
export const MAX_LAYER_COMBINATIONS = 64;

/** Every layer's states added up: what bounds the validation, publication, and review passes. */
export const MAX_PREPARED_STATES = 128;

/**
 * How many states the planner's vision pass will actually look at.
 *
 * Reviewing a layout costs a paid render and a round trip each, and the step budget and timeout in
 * `gateway-plan` are derived from this count. Preparing a cast of characters is cheap because their
 * states add rather than multiply; *looking* at each one is not, so the review stops after enough
 * of them to catch a composition mistake. Every state is still validated.
 */
export const MAX_REVIEWED_STATES = 8;

/** A complete table per group of choice controls, with disjoint properties between groups. */
export function configurationIssues(configuration: Configuration, layerIds: Set<string>): string[] {
  const issues: string[] = [];
  const controls = new Map(configuration.controls.map((control) => [control.id, control]));
  if (controls.size !== configuration.controls.length) issues.push("Control ids must be unique");
  if (new Set(configuration.variants.map((variant) => variant.id)).size !== configuration.variants.length) {
    issues.push("Variant ids must be unique");
  }
  const usedChoices = new Set<string>();
  const properties = new Map<string, string>();
  const claim = (property: string, family: string) => {
    const previous = properties.get(property);
    if (previous && previous !== family) issues.push(`Conflicting bindings for ${property}; combine the choices in one complete variant table`);
    properties.set(property, family);
  };
  for (const control of controls.values()) {
    if (control.type === "choice") {
      const options = new Set(control.options.map((option) => option.id));
      if (options.size !== control.options.length || !options.has(control.defaultValue)) {
        issues.push(`Control ${control.id} needs unique options and an existing default`);
      }
    } else if (control.type === "number") {
      if (control.minimum >= control.maximum || control.defaultValue < control.minimum || control.defaultValue > control.maximum) {
        issues.push(`Control ${control.id} has an invalid numeric range or default`);
      }
      claim("document.speed", control.id);
    } else {
      if (new Set(control.layerIds).size !== control.layerIds.length) issues.push(`Control ${control.id} repeats a layer`);
      for (const id of control.layerIds) {
        if (!layerIds.has(id)) issues.push(`Unknown configurable layer ${id}`);
        claim(`${id}.hidden`, control.id);
      }
    }
  }
  // The cap is per layer rather than per sticker: a cat's pose cannot change how the dog resolves,
  // so two characters at three poses and three moods each are nine states apiece, not eighty-one.
  // Only the controls acting on one layer multiply, which is exactly a sprite's pose and mood.
  let prepared = 0;
  for (const [layerId, count] of configurationLayerCombinations(configuration)) {
    if (count > MAX_LAYER_COMBINATIONS) {
      issues.push(`Character ${layerId} has ${count} mood/pose combinations; at most ${MAX_LAYER_COMBINATIONS} can be prepared. `
        + "Drop an option from one of its controls.");
    }
    prepared += count;
  }
  if (prepared > MAX_PREPARED_STATES) {
    issues.push(`At most ${MAX_PREPARED_STATES} states in total can be prepared, and these controls reach ${prepared}. `
      + "Reduce the number of options, or the number of configurable layers.");
  }
  const families = new Map<string, { count: number; expected: number; selections: Set<string>; targets: string }>();
  for (const variant of configuration.variants) {
    const axes = Object.keys(variant.selections).sort();
    const family = axes.join("|");
    let expected = 1;
    if (!axes.length) issues.push(`Variant ${variant.id} needs a choice selection`);
    for (const axis of axes) {
      const control = controls.get(axis);
      if (control?.type !== "choice" || !control.options.some((option) => option.id === variant.selections[axis])) {
        issues.push(`Variant ${variant.id} has an unknown choice ${axis}`);
      } else {
        usedChoices.add(axis);
        expected *= control.options.length;
      }
    }
    const targets: string[] = [];
    for (const layer of variant.layers) {
      if (!layerIds.has(layer.layerId)) issues.push(`Unknown configurable layer ${layer.layerId}`);
      if (!layer.source && layer.animations === undefined && layer.clip === undefined && layer.expression === undefined && layer.text === undefined && layer.hidden === undefined) {
        issues.push(`Variant ${variant.id} has an empty layer binding`);
      }
      if (layer.source) {
        targets.push(`${layer.layerId}.source`);
        const source = layer.source;
        if ((source.kind === "sequence" || source.kind === "frames") && source.frameCount > source.columns * source.rows) {
          issues.push(`Variant ${variant.id} has more frames than atlas cells`);
        }
      }
      if (layer.animations !== undefined) targets.push(`${layer.layerId}.animations`);
      // Clip and expression are separate properties on purpose: that is what lets a mood control and
      // a pose control act on the same character without a combined table of every pairing.
      if (layer.clip !== undefined) targets.push(`${layer.layerId}.clip`);
      if (layer.expression !== undefined) targets.push(`${layer.layerId}.expression`);
      if (layer.text !== undefined) targets.push(`${layer.layerId}.text`);
      if (layer.hidden !== undefined) targets.push(`${layer.layerId}.hidden`);
    }
    if (new Set(targets).size !== targets.length) issues.push(`Variant ${variant.id} binds a property twice`);
    targets.forEach((target) => claim(target, `choices:${family}`));
    const targetKey = targets.sort().join("|");
    const entry = families.get(family) ?? { count: 0, expected, selections: new Set<string>(), targets: targetKey };
    if (entry.targets !== targetKey) issues.push(`Every option in ${family} must bind the same properties`);
    const selectionKey = axes.map((axis) => variant.selections[axis]).join("|");
    if (entry.selections.has(selectionKey)) issues.push(`Duplicate variant selection in ${family}`);
    entry.selections.add(selectionKey);
    entry.count++;
    families.set(family, entry);
  }
  for (const [family, entry] of families) {
    if (entry.count !== entry.expected) issues.push(`Incomplete variants for ${family}: expected ${entry.expected}, got ${entry.count}`);
  }
  for (const control of controls.values()) {
    if (control.type === "choice" && !usedChoices.has(control.id)) issues.push(`Choice ${control.id} has no variants`);
  }
  return issues;
}

export function normalizedControlValues(configuration: Configuration, values: StickerControlValues = {}): StickerControlValues {
  return Object.fromEntries(configuration.controls.map((control) => {
    const value = values[control.id];
    if (control.type === "choice") return [control.id,
      typeof value === "string" && control.options.some((option) => option.id === value) ? value : control.defaultValue];
    if (control.type === "toggle") return [control.id, typeof value === "boolean" ? value : control.defaultValue];
    return [control.id, typeof value === "number" && Number.isFinite(value)
      ? Math.min(control.maximum, Math.max(control.minimum, value)) : control.defaultValue];
  }));
}

function selectionProduct(controls: readonly StickerControl[]): StickerControlValues[] {
  return controls.reduce<StickerControlValues[]>((states, control) => control.type !== "choice"
    ? states : states.flatMap((state) => control.options.map((option) => ({ ...state, [control.id]: option.id }))), [{}]);
}

export function configurationSelections(configuration: Configuration): StickerControlValues[] {
  return selectionProduct(configuration.controls);
}

/**
 * Which layers a control acts on.
 *
 * A choice control declares nothing about layers of its own; the variants that select it are the
 * only record of what it changes. A toggle names its layers outright, and a speed control belongs
 * to the document rather than to any one layer.
 */
export function controlLayerIds(configuration: Configuration, control: StickerControl): Set<string> {
  if (control.type === "toggle") return new Set(control.layerIds);
  if (control.type === "number") return new Set<string>();
  return new Set(configuration.variants.flatMap((variant) => (
    variant.selections[control.id] === undefined ? [] : variant.layers.map((layer) => layer.layerId)
  )));
}

/** The choice controls acting on each configurable layer, in the order the controls are declared. */
function choicesByLayer(configuration: Configuration): Map<string, StickerControl[]> {
  const byLayer = new Map<string, StickerControl[]>();
  for (const control of configuration.controls) {
    if (control.type !== "choice") continue;
    for (const layerId of controlLayerIds(configuration, control)) {
      byLayer.set(layerId, [...(byLayer.get(layerId) ?? []), control]);
    }
  }
  return byLayer;
}

/**
 * How many states each configurable layer can be prepared in.
 *
 * `claim()` already guarantees no two control families own the same property, so the only controls
 * whose options multiply are the ones acting on the same layer.
 */
export function configurationLayerCombinations(configuration: Configuration): Map<string, number> {
  return new Map([...choicesByLayer(configuration)].map(([layerId, controls]) => [
    layerId, controls.reduce((count, control) => count * (control.type === "choice" ? control.options.length : 1), 1),
  ]));
}

/**
 * The smallest set of selections that still reaches every state any one layer can be in.
 *
 * Validation and publication have to see every alternative, but not every pairing of alternatives
 * belonging to different layers, because no such pairing produces a layer that a per-layer
 * enumeration misses. That is what keeps a two-character sticker at nine states plus nine rather
 * than at eighty-one, and the cost of preparing one flat rather than exponential in its cast.
 *
 * Callers that need a whole-document property checked across layers cannot use this; see the
 * keyframe budget in `StickerDocumentSchema`, which bounds itself per layer instead.
 */
export function configurationCoverage(configuration: Configuration): StickerControlValues[] {
  const perLayer = [...choicesByLayer(configuration).values()].flatMap(selectionProduct);
  const seen = new Map<string, StickerControlValues>();
  // A sticker whose only controls are speed and visibility still has one state to check.
  for (const values of perLayer.length ? perLayer : [{}]) {
    const key = Object.keys(values).sort().map((id) => `${id}=${values[id]}`).join("|");
    if (!seen.has(key)) seen.set(key, values);
  }
  return [...seen.values()];
}

/** The prefix of the coverage set the planner's vision pass walks; see `MAX_REVIEWED_STATES`. */
export function configurationReviewSelections(configuration: Configuration): StickerControlValues[] {
  return configurationCoverage(configuration).slice(0, MAX_REVIEWED_STATES);
}

/** Prioritize edited bindings, rather than spending the review budget on an unchanged cast. */
export function configurationEditReviewSelections(before: Configuration | undefined, after: Configuration): StickerControlValues[] {
  const changed = after.variants.filter((variant) => JSON.stringify(variant) !== JSON.stringify(before?.variants.find((old) => old.id === variant.id)));
  const candidates: StickerControlValues[] = [
    ...changed.map((variant) => variant.selections),
    ...after.controls.flatMap((control): StickerControlValues[] => control.type === "toggle"
      ? [{ [control.id]: true }, { [control.id]: false }] : []),
    {}, ...configurationCoverage(after),
  ];
  const unique = new Map<string, StickerControlValues>();
  for (const candidate of candidates) {
    const values = normalizedControlValues(after, candidate);
    unique.set(JSON.stringify(values), values);
  }
  return [...unique.values()].slice(0, MAX_REVIEWED_STATES);
}

/** Used by layer removal in both authoring paths; control identities otherwise stay unchanged. */
export function configurationKeepingLayers<T extends Configuration>(configuration: T | undefined, layerIds: Set<string>): T | undefined {
  if (!configuration) return undefined;
  const variants = configuration.variants.map((variant) => ({ ...variant, layers: variant.layers.filter((layer) => layerIds.has(layer.layerId)) }))
    .filter((variant) => variant.layers.length > 0);
  const axes = new Set(variants.flatMap((variant) => Object.keys(variant.selections)));
  const controls = configuration.controls.flatMap((control): StickerControl[] => {
    if (control.type === "choice") return axes.has(control.id) ? [control] : [];
    if (control.type === "number") return [control];
    const kept = control.layerIds.filter((id) => layerIds.has(id));
    return kept.length ? [{ ...control, layerIds: kept }] : [];
  });
  return controls.length ? { controls, variants } as T : undefined;
}
