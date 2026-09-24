import { eq } from "drizzle-orm";
import { firstRow, getDatabase } from "@/lib/db/client";
import { stickers } from "@/lib/db/schema";
import { creationPresetReferences } from "./references";
import { creationPresetGuidance, presetUsesPixelArt } from "./selection";

// Read the immutable project snapshot, never the mutable live catalog. Works in durable retries.
async function loadCreationPresetSnapshot(stickerId: string) {
  const row = await (await getDatabase()).select({ presets: stickers.creationPresets }).from(stickers)
    .where(eq(stickers.id, stickerId)).then(firstRow);
  return row?.presets;
}

export async function loadCreationPresetGuidance(stickerId: string): Promise<string> {
  return creationPresetGuidance(await loadCreationPresetSnapshot(stickerId));
}

export async function loadCreationPresetReferences(stickerId: string) {
  return creationPresetReferences(await loadCreationPresetSnapshot(stickerId));
}

/** Everything one image call needs from the snapshot, from a single read. */
export async function loadCreationPresetImageContext(stickerId: string) {
  const snapshot = await loadCreationPresetSnapshot(stickerId);
  return {
    guidance: creationPresetGuidance(snapshot),
    references: await creationPresetReferences(snapshot),
    pixelArt: presetUsesPixelArt(snapshot),
  };
}
