import { eq } from "drizzle-orm";
import { firstRow, getDatabase } from "@/lib/db/client";
import { stickers } from "@/lib/db/schema";
import { creationPresetReferences } from "./references";
import { creationPresetGuidance } from "./selection";

// Read the immutable project snapshot, never the mutable live catalog. Works in durable retries.
export async function loadCreationPresetGuidance(stickerId: string): Promise<string> {
  const row = await (await getDatabase()).select({ presets: stickers.creationPresets }).from(stickers)
    .where(eq(stickers.id, stickerId)).then(firstRow);
  return creationPresetGuidance(row?.presets);
}

export async function loadCreationPresetReferences(stickerId: string) {
  const row = await (await getDatabase()).select({ presets: stickers.creationPresets }).from(stickers)
    .where(eq(stickers.id, stickerId)).then(firstRow);
  return creationPresetReferences(row?.presets);
}
