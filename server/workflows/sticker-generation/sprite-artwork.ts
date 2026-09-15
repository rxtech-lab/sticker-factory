import { eq } from "drizzle-orm";
import { planSpriteLayers, spriteSheetGrid, type PlanV1 } from "@/lib/contracts/plan";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { registerExpressionTiles, registerFaceSlots } from "@/lib/render/sprite-registration";
import { derivedAssetId, ensureSpritePoster, getReadyOwnedAssets } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { generatedLayers, generateAndStoreAsset, type SpriteBuild } from "./asset-generation";
import { validateGeneratedAtlas } from "./configurable-artwork";
import { assertJobStillRunning, beginToolCall, finishToolCall } from "./turn-context";

/**
 * Buying and registering a sprite character's sheets.
 *
 * A sprite layer is built in three kinds of generation after its still has been separated like any
 * other part: one sheet per clip, drawn with a magenta face placeholder that `registerFaceSlots`
 * measures and paints out; one expression sheet of face plates that `registerExpressionTiles`
 * measures; and a poster composited from the two. Every asset id is derived from the confirmed
 * plan's job, so a retried turn reuses whatever it already paid for — and because registration is
 * deterministic, a stored raw sheet is simply measured again rather than trusted to metadata.
 */

type Reference = { bytes: Uint8Array; mimeType: string };
type Job = typeof generationJobs.$inferSelect;
type SpriteSource = Extract<PlanV1["layers"][number]["source"], { kind: "sprite" }>;

/** The two assets a clip leaves behind: what the model drew, and the same sheet with the face slot painted out. */
export function spriteClipAssetIds(jobId: string, layerId: string, clipId: string): { raw: string; clean: string } {
  return {
    raw: derivedAssetId(jobId, `sprite-raw:${layerId}:${clipId}`),
    clean: derivedAssetId(jobId, `sprite:${layerId}:${clipId}`),
  };
}

export function spriteExpressionAssetId(jobId: string, layerId: string): string {
  return derivedAssetId(jobId, `sprite-expressions:${layerId}`);
}

/** Near-square cells for face plates: 2x2 up to four, 3x2 up to six, 3x3 up to nine. */
export function expressionSheetGrid(count: number): { columns: number; rows: number } {
  return count <= 4 ? { columns: 2, rows: 2 } : count <= 6 ? { columns: 3, rows: 2 } : { columns: 3, rows: 3 };
}

const characterReference = (name: string) =>
  `Use the approved sticker as the exact character reference: preserve the ${name}'s silhouette, colours, outlines, shading, texture, and proportions.`;

export function spriteClipPrompt(layer: { name: string }, source: SpriteSource, clip: SpriteSource["clips"][number]): string {
  const count = clip.frames.length;
  return [
    characterReference(layer.name),
    `Draw only the ${layer.name} character, with nothing else from the sticker, as ${count} animation frame${count === 1 ? "" : "s"} of one motion — ${clip.label}: ${clip.prompt}`,
    count > 1
      ? "Frame 1 is the resting pose. The frames read in order and loop back to frame 1, so the last frame leads naturally into the first. Change only what the motion moves; the body keeps the same size and position in every cell."
      : "This is a single held pose.",
    `Character: ${source.prompt}`,
  ].join(" ");
}

export function spriteExpressionPrompt(layer: { name: string }, source: SpriteSource): string {
  const list = source.expressions.map((expression, index) => `${index + 1}. ${expression.label}: ${expression.prompt}`).join("; ");
  return [
    `Use the approved sticker as the exact reference for the ${layer.name}'s face: its design, style, palette, and line weight.`,
    `Draw ${source.expressions.length} version${source.expressions.length === 1 ? "" : "s"} of only the ${layer.name}'s face plate, one per cell, each with a different expression, in this order: ${list}.`,
    "The plate is the oval of skin, fur, or surface the features sit on, from brow to chin and cheek to cheek, cut out cleanly with its own outline; it is the same size and position in every cell and faces the same way as in the reference. Only the expression changes between cells.",
  ].join(" ");
}

async function storeSheetAsset(
  job: Job, stickerId: string, assetId: string, bytes: Uint8Array,
  grid: { columns: number; rows: number; frameCount: number; frameRate: number; durationSeconds: number },
): Promise<void> {
  const db = await getDatabase();
  const existing = await db.select({ state: assets.state }).from(assets).where(eq(assets.id, assetId)).then(firstRow);
  if (existing?.state === "ready") return;
  const inspection = await inspectImage(bytes);
  const r2Key = objectKey(job.ownerId, assetId, "image/png");
  await getObjectStore().put(r2Key, { bytes, contentType: "image/png", metadata: { sha256: inspection.sha256 } });
  await db.insert(assets).values({
    id: assetId, ownerId: job.ownerId, stickerId, kind: "sequence", state: "ready", r2Key, mimeType: "image/png",
    sequenceColumns: grid.columns, sequenceRows: grid.rows, frameCount: grid.frameCount, fps: grid.frameRate, durationSeconds: grid.durationSeconds,
    byteSize: inspection.byteSize, width: inspection.width, height: inspection.height, sha256: inspection.sha256,
    hasAlpha: inspection.hasTransparentPixels, createdAt: new Date(), readyAt: new Date(),
  }).onConflictDoUpdate({ target: assets.id, set: {
    state: "ready", byteSize: inspection.byteSize, sha256: inspection.sha256, width: inspection.width, height: inspection.height,
    hasAlpha: inspection.hasTransparentPixels, readyAt: new Date(),
  } });
}

/** Flips a drawn sheet to failed so the next attempt buys another instead of re-measuring a bad one. */
async function discardSheet(assetId: string): Promise<void> {
  const db = await getDatabase();
  await db.update(assets).set({ state: "failed" }).where(eq(assets.id, assetId));
}

async function buildClip(
  job: Job, stickerId: string, assetJobId: string, layer: PlanV1["layers"][number], source: SpriteSource,
  clip: SpriteSource["clips"][number], references: Reference[],
): Promise<SpriteBuild["clips"][number]> {
  const grid = spriteSheetGrid(clip.frames.length);
  const frameCount = clip.frames.length;
  const durationSeconds = clip.frames.reduce((total, frame) => total + frame.duration, 0);
  const ids = spriteClipAssetIds(assetJobId, layer.layerId, clip.id);
  await generateAndStoreAsset(job, stickerId, {
    assetId: ids.raw, references, mode: "conversation_edit", keepFrame: true, quality: "medium",
    sheet: { ...grid, count: frameCount, facePlaceholder: true },
    sequence: { ...grid, frameCount, frameRate: frameCount / durationSeconds },
    prompt: spriteClipPrompt(layer, source, clip),
  });
  const raw = await getObjectStore().get(objectKey(job.ownerId, ids.raw, "image/png"));
  let registered: Awaited<ReturnType<typeof registerFaceSlots>>;
  try {
    await validateGeneratedAtlas(raw.bytes, { ...grid, frameCount });
    registered = await registerFaceSlots(raw.bytes, { ...grid, frameCount });
  } catch (error) {
    await discardSheet(ids.raw);
    throw error;
  }
  await storeSheetAsset(job, stickerId, ids.clean, registered.bytes, { ...grid, frameCount, frameRate: frameCount / durationSeconds, durationSeconds });
  return {
    id: clip.id, assetId: ids.clean, columns: grid.columns, rows: grid.rows,
    frames: clip.frames.map((frame, index) => ({ duration: frame.duration, ...registered.frames[index] })),
  };
}

async function buildExpressions(
  job: Job, stickerId: string, assetJobId: string, layer: PlanV1["layers"][number], source: SpriteSource, references: Reference[],
): Promise<SpriteBuild["expressions"]> {
  const count = source.expressions.length;
  const grid = expressionSheetGrid(count);
  const assetId = spriteExpressionAssetId(assetJobId, layer.layerId);
  await generateAndStoreAsset(job, stickerId, {
    assetId, references, mode: "conversation_edit", keepFrame: true, quality: "medium",
    sheet: { ...grid, count, tiles: true },
    sequence: { ...grid, frameCount: count, frameRate: 1 },
    prompt: spriteExpressionPrompt(layer, source),
  });
  const sheet = await getObjectStore().get(objectKey(job.ownerId, assetId, "image/png"));
  try {
    await validateGeneratedAtlas(sheet.bytes, { ...grid, frameCount: count });
    const tiles = await registerExpressionTiles(sheet.bytes, { ...grid, frameCount: count });
    return { assetId, ...grid, tiles: tiles.map((tile, index) => ({ id: source.expressions[index].id, ...tile })) };
  } catch (error) {
    await discardSheet(assetId);
    throw error;
  }
}

/**
 * Builds every sprite layer of a confirmed plan and returns what `documentFromPlan` needs for each.
 *
 * Runs after the stills, because each sheet is drawn from the layer's own separated still as well
 * as the approved reference. Sheets are bought one at a time: a sprite is several generations, and
 * a turn that is going to fail on its second should fail before paying for the rest.
 */
export async function generateSpriteArtwork(
  job: Job, stickerId: string, plan: PlanV1, assetJobId: string, reference: Reference | undefined,
): Promise<Map<string, SpriteBuild>> {
  const builds = new Map<string, SpriteBuild>();
  const sprites = planSpriteLayers(plan);
  if (sprites.length === 0) return builds;
  if (!reference) throw new Error("A sprite character needs the approved static reference");
  const db = await getDatabase();
  const store = getObjectStore();
  const stills = new Map(generatedLayers(plan, assetJobId).map((item) => [item.layer.layerId, item.assetId]));
  const total = sprites.reduce((sum, { source }) => sum + source.clips.length + 1, 0);
  let done = 0;
  const progress = async (partName: string) => {
    done += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_sprite", progress: 0.05 + 0.7 * (done / total), partName, sheetIndex: done - 1, sheetCount: total,
    });
  };

  for (const { layer, source } of sprites) {
    const stillId = stills.get(layer.layerId);
    if (!stillId) throw new Error(`Sprite layer ${layer.layerId} has no separated still`);
    const [stillRow] = await getReadyOwnedAssets(db, job.ownerId, [stillId]);
    const still = { bytes: (await store.get(stillRow.r2Key)).bytes, mimeType: stillRow.mimeType };
    const references = [reference, still];

    const clips: SpriteBuild["clips"] = [];
    for (const clip of source.clips) {
      await assertJobStillRunning(job.id);
      const call = await beginToolCall(job, "build-plan", undefined, `compose-sprite ${layer.name} ${clip.id}`);
      try {
        clips.push(await buildClip(job, stickerId, assetJobId, layer, source, clip, references));
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
      await finishToolCall(job, call, "complete", { previewAssetId: clips.at(-1)!.assetId });
      await progress(`${layer.name} ${clip.label}`);
    }

    await assertJobStillRunning(job.id);
    const call = await beginToolCall(job, "build-plan", undefined, `compose-sprite ${layer.name} expressions`);
    let expressions: SpriteBuild["expressions"];
    try {
      expressions = await buildExpressions(job, stickerId, assetJobId, layer, source, references);
    } catch (error) {
      await finishToolCall(job, call, "failed", error);
      throw error;
    }
    await finishToolCall(job, call, "complete", { previewAssetId: expressions.assetId });
    await progress(`${layer.name} expressions`);

    const posterAssetId = await ensureSpritePoster(db, job.ownerId, stickerId, {
      clip: clips[0], expressions: { assetId: expressions.assetId }, tile: expressions.tiles[0],
    });
    builds.set(layer.layerId, { clips, expressions, posterAssetId });
  }
  return builds;
}
