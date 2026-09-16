import { z } from "zod";

/** Number of independently selectable body clips per character, including idle. */
export const PosePresetSchema = z.enum(["low", "medium", "high", "ultra"]);
export type PosePreset = z.infer<typeof PosePresetSchema>;
export const POSE_COUNTS: Record<PosePreset, number> = { low: 2, medium: 3, high: 5, ultra: 8 };
