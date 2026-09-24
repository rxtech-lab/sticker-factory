import type { CreationPresetCatalog, CreationPresetDisplay, CreationPresetSnapshot, CreationPresetSubmission } from "@/lib/contracts/creation-presets";
import { ApiError } from "@/lib/http/errors";
import { creationPresetCatalog, PIXEL_ART_STYLE_IDS, SHARED_PRESET_PROMPT } from "./catalog";

export function resolveCreationPresets(submission: CreationPresetSubmission | undefined, catalog: CreationPresetCatalog = creationPresetCatalog): CreationPresetSnapshot | null {
  // Omitted by older apps, quick creation, and imports. New guided clients always submit a catalog.
  if (!submission) return null;
  if (submission.catalogVersion !== catalog.version) {
    throw new ApiError(409, "CREATION_PRESETS_CHANGED", "Sticker options have changed. Review your choices before generating.", { catalogVersion: catalog.version });
  }
  const invalid = (message: string): never => { throw new ApiError(422, "INVALID_CREATION_PRESETS", message); };
  const selections = new Map<string, string[]>();
  for (const selection of submission.selections) {
    if (selections.has(selection.groupId) || !catalog.groups.some((group) => group.id === selection.groupId)) invalid("Unknown or repeated choice group");
    if (new Set(selection.optionIds).size !== selection.optionIds.length) invalid("Repeated preset option");
    selections.set(selection.groupId, selection.optionIds);
  }
  const snapshot: CreationPresetSnapshot = { catalogVersion: catalog.version, sharedPrompt: SHARED_PRESET_PROMPT, selections: [] };
  for (const group of catalog.groups) {
    const ids = selections.get(group.id) ?? [];
    if (ids.length < group.minSelections || ids.length > group.maxSelections) invalid(`Choose ${group.minSelections}–${group.maxSelections} options for ${group.title.en}`);
    if (ids.some((id) => !group.options.some((option) => option.id === id))) invalid(`Unknown option for ${group.title.en}`);
    if (ids.length) snapshot.selections.push({ groupId: group.id, title: { ...group.title }, options: group.options.filter((option) => ids.includes(option.id)).map((option) => structuredClone(option)) });
  }
  return snapshot;
}

export function creationPresetDisplay(snapshot: CreationPresetSnapshot | null | undefined): CreationPresetDisplay | null {
  if (!snapshot) return null;
  return { catalogVersion: snapshot.catalogVersion, selections: snapshot.selections.map((group) => ({
    groupId: group.groupId, title: group.title,
    options: group.options.map(({ id, title, cover, preview }) => ({ id, title, cover, ...(preview ? { preview } : {}) })),
  })) };
}

export function creationPresetGuidance(snapshot: CreationPresetSnapshot | null | undefined): string {
  if (!snapshot?.selections.length) return "";
  return ["Saved project presets (creative guidance):", snapshot.sharedPrompt,
    ...snapshot.selections.flatMap((group) => group.options.map((option) => `${group.title.en}: ${option.title.en}. ${option.prompt}`)),
  ].join("\n");
}

/** A pixel style's output is resampled with nearest-neighbour and a hard alpha edge, never smoothed. */
export function presetUsesPixelArt(snapshot: CreationPresetSnapshot | null | undefined): boolean {
  return Boolean(snapshot?.selections.some((group) => group.groupId === "style" && group.options.some((option) => PIXEL_ART_STYLE_IDS.has(option.id))));
}
