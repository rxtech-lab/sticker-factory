import { and, eq } from "drizzle-orm";
import { getAiProvider } from "@/lib/ai/gateway";
import type { AiPetActionsContext, PetAction } from "@/lib/ai/gateway-contracts";
import { PetActionV1Schema } from "@/lib/contracts/api";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, type PetStoredContext, type stickerRevisions, type stickers, type UserPetRow } from "@/lib/db/schema";
import { describeError } from "@/lib/observability/trace";
import { petLog } from "@/lib/pets/log";
import { downscaleForModelInput, getObjectStore } from "@/lib/storage/r2";

type Sticker = typeof stickers.$inferSelect;
type Revision = typeof stickerRevisions.$inferSelect;

/** The actions the agent offers for this pet, given whatever it knows of the pet's mood. Throws when it cannot. */
export async function generateActions(
  db: Database,
  sticker: Sticker,
  revision: Revision,
  mood: Omit<AiPetActionsContext, "petTitle" | "controls" | "image"> = {},
): Promise<PetAction[]> {
  const generated = await getAiProvider().generatePetActions({
    petTitle: sticker.title,
    controls: revision.playbackJson?.document.configuration?.controls ?? [],
    image: await sentStickerImage(db, revision.pngAssetId ?? revision.systemAssetId),
    ...mood,
  });
  return PetActionV1Schema.array().min(1).max(5).parse(
    generated.map((action) => ({ ...action, id: crypto.randomUUID() })),
  );
}

/**
 * A fresh set of actions for a pet whose mood just changed, or undefined when the agent cannot
 * answer — the pet then keeps the actions it has, so a mood change never fails over its actions.
 */
export async function refreshActions(
  db: Database,
  pet: UserPetRow,
  sticker: Sticker,
  revision: Revision,
  mood: { stats: AiPetActionsContext["stats"]; mood: string | null; signals?: AiPetActionsContext["signals"] },
): Promise<PetAction[] | undefined> {
  try {
    return await generateActions(db, sticker, revision, {
      identity: pet.identityJson,
      signals: mood.signals ?? pet.signalsJson,
      stats: mood.stats,
      mood: mood.mood,
      previous: pet.actionsJson?.map((action) => action.title) ?? [],
      ...ownerMoment(pet.contextJson),
    });
  } catch (error) {
    petLog("actions:refresh-failed", { userId: pet.userId, error: describeError(error) });
    return undefined;
  }
}

/**
 * When and where the owner is, as the action agent reads it: their local time, in their own time
 * zone when the phone has told us one, and their rounded location when they have shared it.
 */
export function ownerMoment(context: PetStoredContext | null, now = new Date()): Pick<AiPetActionsContext, "localTime" | "location"> {
  const format = (timeZone?: string) => new Intl.DateTimeFormat("en-GB", {
    weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit", hour12: false, timeZone,
  }).format(now);
  let localTime: string;
  try {
    localTime = format(context?.timeZone);
  } catch {
    localTime = `${format("UTC")} UTC`;
  }
  const location = context?.latitude !== undefined && context.longitude !== undefined
    ? { latitude: Math.round(context.latitude * 100) / 100, longitude: Math.round(context.longitude * 100) / 100 } : null;
  return { localTime, location };
}

/** A sticker's picture, downscaled for a model to look at. Optional: the title still reads. */
export async function sentStickerImage(db: Database, assetId: string | null) {
  if (!assetId) return null;
  try {
    const asset = await db.select().from(assets).where(and(eq(assets.id, assetId), eq(assets.state, "ready"))).then(firstRow);
    if (!asset) return null;
    return await downscaleForModelInput((await getObjectStore().get(asset.r2Key)).bytes);
  } catch {
    return null;
  }
}
