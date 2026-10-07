import type { PetTouch, PetTouchResponseV1 } from "@/lib/contracts/pet-touch";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { petLog } from "@/lib/pets/log";
import { currentStats, petRow } from "./pet-state";
import { decidePetPose } from "./pet-pose";
import { lastPublishedPlayback } from "./playback";

/** What each touch felt like, from the pet's side. */
const TOUCH_DESCRIPTIONS: Record<PetTouch, string> = {
  tap: "tapped it gently",
  release: "let go of it after a cuddle",
  held_too_long: "held it for far too long",
  swipe_left: "stroked it",
  swipe_right: "stroked it",
  swipe_up: "lifted it up",
  swipe_down: "pressed it down",
  overwhelmed: "tapped it over and over, far too quickly",
  shaken: "shook the phone it lives in, rattling it about",
};

/** A touch only answers quickly or not at all: past this the pet's body has long moved on. */
const TOUCH_DECISION_TIMEOUT_MS = 3_000;

export function touchMoment(touch: PetTouch): string {
  return `Its owner just ${TOUCH_DESCRIPTIONS[touch]}.`;
}

/**
 * The pose the caller's pet switches to, for a moment, in reaction to `touch`, decided by the pet's
 * decision model from its sticker's own controls, against the pose the phone shows (`shown` over the
 * stored one): only the controls it changed. Nothing is stored —
 * the pose it holds is still the last interaction's. Empty when the model does not answer in time;
 * the pet's body has already reacted.
 */
export async function decidePetTouchPose(
  db: Database,
  userId: string,
  touch: PetTouch,
  shown?: Record<string, string | boolean>,
): Promise<PetTouchResponseV1> {
  const row = await petRow(db, userId);
  if (!row) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
  let playback;
  try {
    playback = await lastPublishedPlayback(db, userId, row.stickerId);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) throw new ApiError(404, "PET_NOT_FOUND", "You have not chosen a pet.");
    throw error;
  }
  const configuration = playback.revision.playbackJson?.document.configuration;
  if (!configuration) return { values: {} };
  // What the owner sees: the stored pose, with whatever the last touch moved laid over it.
  const current = normalizedControlValues(configuration, { ...row.statusJson?.values, ...shown });
  const decided = await decidePetPose(configuration, current, {
    petTitle: playback.sticker.title, identity: row.identityJson, stats: currentStats(row), illness: row.illnessJson?.name,
    moment: touchMoment(touch),
  }, TOUCH_DECISION_TIMEOUT_MS);
  const values = Object.fromEntries(Object.entries(decided ?? {}).filter(([id, value]) => value !== current[id]));
  petLog("touch", { userId, touch, current, changed: values });
  return { values };
}
