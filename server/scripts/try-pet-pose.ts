// Touches a real pet a few times and asks its decision model (AI_PET_DECISION_MODEL) for each pose,
// from that pet's own sticker controls, to see the `[pet]` logs. Then taps it once more in a few
// made-up conditions — joyful, exhausted, sick — to see how its status moves the pose. Nothing is written.
//
//   bun --env-file=.env scripts/try-pet-pose.ts [userId]
//
// Without a user id it takes the pet adopted or moved most recently.
import { desc } from "drizzle-orm";
import { normalizedControlValues } from "@/lib/contracts/configuration";
import { firstRow, getDatabase } from "@/lib/db/client";
import { userPets } from "@/lib/db/schema";
import type { PetTouch } from "@/lib/contracts/pet-touch";
import { petRow } from "@/lib/services/pet-state";
import { decidePetPose } from "@/lib/services/pet-pose";
import { decidePetTouchPose, touchMoment } from "@/lib/services/pet-touch";
import { readablePlayback } from "@/lib/services/playback";

const db = await getDatabase();
const userId = process.argv[2]
  ?? (await db.select({ userId: userPets.userId }).from(userPets).orderBy(desc(userPets.updatedAt)).limit(1).then(firstRow))?.userId;
if (!userId) throw new Error("No pet found.");

// Each touch switches away from the pose the one before it left showing, as the phone does.
let shown: Record<string, string | boolean> = {};
for (const touch of ["tap", "swipe_left", "shaken"] satisfies PetTouch[]) {
  const { values } = await decidePetTouchPose(db, userId, touch, shown);
  shown = { ...shown, ...values };
}

const row = (await petRow(db, userId))!;
const { sticker, revision } = await readablePlayback(db, userId, row.stickerId);
const configuration = revision.playbackJson!.document.configuration!;
const current = normalizedControlValues(configuration, row.statusJson?.values ?? {});
const conditions = {
  joyful: { stats: { happiness: 95, energy: 90, hp: row.identityJson?.maxHp ?? 100 } },
  exhausted: { stats: { happiness: 50, energy: 8, hp: row.identityJson?.maxHp ?? 100 } },
  sick: { stats: { happiness: 30, energy: 40, hp: 15 }, illness: "a fever" },
};
for (const condition of Object.values(conditions)) {
  await decidePetPose(configuration, current, {
    petTitle: sticker.title, identity: row.identityJson, moment: touchMoment("tap"), ...condition,
  }, 10_000);
}
