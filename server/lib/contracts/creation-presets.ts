import { z } from "zod";

const ID = z.string().regex(/^[a-z][a-z0-9-]{0,63}$/);
export const PresetTextSchema = z.object({ en: z.string().min(1), "zh-Hans": z.string().min(1), "zh-Hant": z.string().min(1) }).strict();
export type PresetText = z.infer<typeof PresetTextSchema>;
export const CreationPresetSubmissionSchema = z.object({
  catalogVersion: z.string().min(1).max(80),
  selections: z.array(z.object({ groupId: ID, optionIds: z.array(ID).max(12) }).strict()).max(20),
}).strict();
export type CreationPresetSubmission = z.infer<typeof CreationPresetSubmissionSchema>;
const PreviewChoiceSchema = z.object({ id: ID, title: PresetTextSchema }).strict();
export const CreationPreviewSchema = z.object({
  url: z.string().min(1), defaultPose: ID, defaultMood: ID,
  poses: z.array(PreviewChoiceSchema).min(2).max(8), moods: z.array(PreviewChoiceSchema).min(1).max(8),
  variants: z.array(z.object({ pose: ID, mood: ID, url: z.string().min(1) }).strict()).min(2).max(64),
}).strict().superRefine((preview, ctx) => {
  const poses = new Set(preview.poses.map(choice => choice.id));
  const moods = new Set(preview.moods.map(choice => choice.id));
  const pairs = new Set(preview.variants.map(item => `${item.pose}/${item.mood}`));
  if (poses.size !== preview.poses.length || moods.size !== preview.moods.length
    || !poses.has(preview.defaultPose) || !moods.has(preview.defaultMood)
    || pairs.size !== poses.size * moods.size || pairs.size !== preview.variants.length
    || preview.variants.some(item => !poses.has(item.pose) || !moods.has(item.mood))) {
    ctx.addIssue({ code: "custom", message: "Every preview pose and mood must have exactly one animation" });
  }
});
export const PresetOptionDisplaySchema = z.object({
  id: ID, title: PresetTextSchema, cover: z.string().min(1), preview: CreationPreviewSchema.optional(),
}).strict();
export const PresetSelectionDisplaySchema = z.object({
  groupId: ID, title: PresetTextSchema, options: z.array(PresetOptionDisplaySchema),
}).strict();
export const CreationPresetDisplaySchema = z.object({
  catalogVersion: z.string(), selections: z.array(PresetSelectionDisplaySchema),
}).strict();
export type CreationPresetDisplay = z.infer<typeof CreationPresetDisplaySchema>;
export type CreationPresetSnapshot = {
  catalogVersion: string;
  sharedPrompt: string;
  selections: Array<Omit<z.infer<typeof PresetSelectionDisplaySchema>, "options"> & {
    options: Array<z.infer<typeof PresetOptionDisplaySchema> & { prompt: string }>;
  }>;
};

export const CreationPresetCatalogSchema = z.object({
  version: z.string().min(1),
  groups: z.array(z.object({
    id: ID, type: z.enum(["single_choice", "multiple_choice"]),
    title: PresetTextSchema, description: PresetTextSchema,
    minSelections: z.number().int().min(0), maxSelections: z.number().int().min(1).max(12),
    options: z.array(PresetOptionDisplaySchema.extend({ prompt: z.string().min(1) })).min(1).max(12),
  }).strict()).max(20),
}).strict().superRefine((catalog, ctx) => {
  const groupIds = new Set<string>();
  for (const [i, group] of catalog.groups.entries()) {
    const invalid = groupIds.has(group.id) || group.minSelections > group.maxSelections
      || group.maxSelections > group.options.length
      || (group.type === "single_choice" && group.maxSelections !== 1)
      || new Set(group.options.map((option) => option.id)).size !== group.options.length;
    if (invalid) ctx.addIssue({ code: "custom", path: ["groups", i], message: "Invalid choice group or selection limits" });
    groupIds.add(group.id);
  }
});
export type CreationPresetCatalog = z.infer<typeof CreationPresetCatalogSchema>;
