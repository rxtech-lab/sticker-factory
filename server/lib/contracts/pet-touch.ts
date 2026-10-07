import { z } from "zod";

/** The ways the owner can touch their pet on the phone. */
export const PET_TOUCHES = [
  "tap", "release", "held_too_long", "swipe_left", "swipe_right", "swipe_up", "swipe_down", "overwhelmed", "shaken",
] as const;
export type PetTouch = (typeof PET_TOUCHES)[number];

/** A touch, for the pet to strike a pose in reaction to. */
export const PetTouchRequestSchema = z.object({
  touch: z.enum(PET_TOUCHES),
  /** The pose the phone shows now, when a touch before this one moved it off the stored pose. */
  pose: z.record(z.string().max(64), z.union([z.string().max(64), z.boolean()])).optional(),
}).strict();
export type PetTouchRequest = z.infer<typeof PetTouchRequestSchema>;

/** The controls the pet changed in reaction to a touch; empty when it holds its pose. Never stored. */
export const PetTouchResponseV1Schema = z.object({
  values: z.record(z.string(), z.union([z.string(), z.boolean()])),
}).strict();
export type PetTouchResponseV1 = z.infer<typeof PetTouchResponseV1Schema>;
