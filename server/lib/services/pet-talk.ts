// What the owner says to their pet moves its body too: the decision model poses it for the talk.

import { and, eq, isNull } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { RememberPetTalkRequest } from "@/lib/contracts/api";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import type { Database } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { notifyPetStatusChanged } from "@/lib/notifications/pet";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { ownerMoment } from "./pet-actions";
import { currentStats, petRow } from "./pet-state";
import { getPet, type PetResponse } from "./pets";
import { readablePlayback } from "./playback";

/**
 * Has the decision model pose the pet for something its owner just said to it and its answer, so
 * its body answers too. Only the pose and how often it animates change; its line, stats and diary
 * stay as they are. Skipped while another interaction is changing the pet, which poses it anyway.
 */
export async function posePetForTalk(
  db: Database,
  userId: string,
  input: RememberPetTalkRequest,
  notify: (db: Database, userId: string) => Promise<void> = notifyPetStatusChanged,
): Promise<PetResponse> {
  const pet = await petRow(db, userId);
  if (!pet) throw new ApiError(404, "PET_NOT_FOUND", "Choose a pet first.");
  const { sticker, revision } = await readablePlayback(db, userId, pet.stickerId);
  const configuration = revision.playbackJson?.document.configuration;
  if (!configuration?.controls.length || pet.interactionId) return getPet(db, userId);
  const pose = await getAiProvider().decidePetPose({
    petTitle: sticker.title,
    identity: pet.identityJson,
    stats: currentStats(pet),
    controls: configuration.controls,
    current: pet.statusJson?.values ?? null,
    words: input.words,
    reply: input.reply ?? null,
    ...ownerMoment(pet.contextJson),
  });
  const values = normalizedControlValues(configuration, { ...pet.statusJson?.values, ...pose.values });
  const updated = await db.update(userPets).set({
    statusJson: {
      ...pet.statusJson,
      values,
      caption: pet.statusJson?.caption ?? input.reply ?? "",
      animateEverySeconds: pose.animateEverySeconds ?? pet.statusJson?.animateEverySeconds,
    },
    statusUpdatedAt: new Date(),
  }).where(and(eq(userPets.userId, userId), eq(userPets.stickerId, pet.stickerId), isNull(userPets.interactionId)))
    .returning({ userId: userPets.userId });
  if (updated.length) {
    petLog("talk:posed", { userId, values });
    await notify(db, userId).catch((error) => traceEvent("pet.talk:notify:failed", { userId, error: describeError(error) }));
  }
  return getPet(db, userId);
}
