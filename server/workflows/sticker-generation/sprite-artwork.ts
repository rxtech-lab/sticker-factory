import { SpriteClipV1Schema, SpriteExpressionsV1Schema } from "@/lib/contracts/sprite";
import { loadBuildCheckpoint, saveBuildCheckpoint, buildAssetsReady, completedBuildSteps } from "./build-checkpoints";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { planSpriteLayers, spriteSheetGrid, type PlanV1 } from "@/lib/contracts/plan";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, generationJobs } from "@/lib/db/schema";
import { registerExpressionTiles, registerFaceSlots } from "@/lib/render/sprite-registration";
import { padGeneratedAtlas } from "@/lib/render/sprite-atlas";
import { derivedAssetId, ensureSpritePoster, getReadyOwnedAssets } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { getAiProvider, type AiSheetInspectionContext } from "@/lib/ai/gateway";
import { generatedLayers, generateAndStoreAsset, type SpriteBuild } from "./asset-generation";
import { validateGeneratedAtlas } from "./configurable-artwork";
import { assertJobStillRunning, beginToolCall, finishToolCall, reportTurnNote } from "./turn-context";

/**
 * Buying and registering a sprite character's sheets.
 *
 * A sprite layer is built in three kinds of generation after its still has been separated like any
 * other part: one sheet per clip, drawn with a magenta face placeholder that `registerFaceSlots`
 * measures and paints out; one expression sheet of face plates that `registerExpressionTiles`
 * measures; and a poster composited from the two. Every asset id is derived from the confirmed
 * plan's job, so a retried turn reuses whatever it already paid for — and because registration is
 * deterministic, registered sheets are checkpointed; older stored raw sheets are measured once
 * to recover their registration before saving a checkpoint.
 *
 * Registration proves the shape of a sheet, not its content: a magenta oval in every cell says
 * nothing about the mouth the model also left on the bumper. So every sheet is shown to a vision
 * inspector once it registers, and a sheet it rejects is redrawn once with the problems appended
 * to the prompt before the build gives up on it.
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

/** What a rejected sheet was rejected for, so the one redraw it earns can be told what to fix. */
export class SheetRejected extends Error {
  constructor(readonly problems: string[]) {
    super(`Generated sheet was rejected: ${problems.join("; ")}`);
    this.name = "SheetRejected";
  }
}

async function inspectOrThrow(input: AiSheetInspectionContext): Promise<void> {
  const verdict = await getAiProvider().inspectSpriteSheet(input);
  if (!verdict.ok) throw new SheetRejected(verdict.problems);
}

/** The plan's face region, or the assumption the prompts made before the plan could name one. */
const faceRegion = (source: SpriteSource) => source.face ?? "the character's head, where the eyes and mouth are";

const feedbackInstruction = (problems?: string[]) => (problems?.length
  ? `A previous attempt was rejected: ${problems.join("; ")}. Fix every listed problem in this drawing.`
  : undefined);

const characterReference = (name: string) =>
  `Use the approved sticker as the exact character reference: preserve the ${name}'s silhouette, colours, outlines, shading, texture, and proportions.`;

const animationSummaryInstruction = "Reference 1 is the approved resting composition; reference 2 is this character's separated still. Reference 3 is the approved illustrated animation summary: follow the labelled poses and facial expressions for the requested motion or mood while preserving the character design from references 1 and 2. Use the written plan for exact frame order, count and timing. Do not copy the summary's panels, captions, arrows, extra characters or background into the generated artwork.";

export function spriteClipPrompt(layer: { name: string }, source: SpriteSource, clip: SpriteSource["clips"][number], hasAnimationSummary = false, feedback?: string[]): string {
  const count = clip.frames.length;
  return [
    characterReference(layer.name),
    ...(hasAnimationSummary ? [animationSummaryInstruction] : []),
    `Draw only the ${layer.name} character, with nothing else from the sticker, as ${count} animation frame${count === 1 ? "" : "s"} of one motion — ${clip.label}: ${clip.prompt}`,
    count > 1
      ? "Frame 1 is the resting pose. The frames read in order and loop back to frame 1, so the last frame leads naturally into the first. Change only what the motion moves; the body keeps the same size and position in every cell."
      : "This is a single held pose.",
    `Character: ${source.prompt}`,
    "Perform the motion in place around a fixed body anchor, with a locked camera and no zoom. Reserve room for the entire motion, including leaning, bouncing, extended parts, and any requested effects. Keep the complete silhouette inside the cell's transparent safety margins in every frame. Do not add ground, scenery, speed lines, smoke, or skid marks unless explicitly requested; requested effects must also fit inside the same safe area.",
    `Keep the complete outer silhouette of the head or front — ears, hair, fur, shell, casing, windshield frame — on this body layer. The face region is ${faceRegion(source)}. Replace every facial feature the character has with the single magenta face opening there; no eye, brow, nose, or mouth may remain anywhere on the body outside it, whether on a grille, bumper, chest, screen, or panel. Preserve the reference's pixel grid and hard pixel edges when it is pixel art.`,
    feedbackInstruction(feedback),
  ].filter(Boolean).join(" ");
}

export function spriteExpressionPrompt(layer: { name: string }, source: SpriteSource, hasAnimationSummary = false, feedback?: string[]): string {
  const list = source.expressions.map((expression, index) => `${index + 1}. ${expression.label}: ${expression.prompt}`).join("; ");
  return [
    `Use the approved sticker as the exact reference for the ${layer.name}'s face: its design, style, palette, and line weight.`,
    ...(hasAnimationSummary ? [animationSummaryInstruction] : []),
    `Draw ${source.expressions.length} version${source.expressions.length === 1 ? "" : "s"} of only the ${layer.name}'s face plate, one per cell, each with a different expression, in this order: ${list}.`,
    "The last reference is the actual body frame with a magenta opening. Draw only the inner facial patch that replaces that opening, matching its shape, proportions, viewing angle, and surrounding skin, fur, or surface colour. The earlier references supply the original facial identity and style. Do not copy the magenta colour.",
    `Do not draw a second head, miniature portrait, ears, hair, fur, shell, casing, neck, or body. Those already exist on the body layer. This patch is the character's only face: draw the eyes, brows, nose, mouth, cheeks, and the surface directly beneath them, filling ${faceRegion(source)} edge to edge. No enclosing outline, sticker border, rim, or shadow around the patch; its edge must blend into the surrounding body when composited.`,
    "Keep the patch the same size and position in every cell; only the expression changes. Preserve the reference's pixel grid, hard pixel edges, palette, and shading when it is pixel art; do not turn it into a smooth portrait.",
    feedbackInstruction(feedback),
  ].filter(Boolean).join(" ");
}

async function storeSheetAsset(
  job: Job, stickerId: string, assetId: string, bytes: Uint8Array,
  grid: { columns: number; rows: number; frameCount: number; frameRate: number; durationSeconds: number },
  replaceReady = false,
): Promise<void> {
  const db = await getDatabase();
  const existing = await db.select({ state: assets.state }).from(assets).where(eq(assets.id, assetId)).then(firstRow);
  if (existing?.state === "ready" && !replaceReady) return;
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

/** Failed sheets are not reused unless they can be repaired and fully registered. */
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
  const sheetGrid = { ...grid, frameCount };
  const prepare = async (original: Uint8Array) => {
    let bytes = original;
    try { await validateGeneratedAtlas(bytes, sheetGrid); }
    catch (error) {
      // Padding an already-cut cell cannot restore missing pixels. Find clear seams on the
      // original sheet first, and keep the original validation error if that is impossible.
      try { bytes = await padGeneratedAtlas(bytes, sheetGrid); }
      catch { throw error; }
      await validateGeneratedAtlas(bytes, sheetGrid);
    }
    const registered = await registerFaceSlots(bytes, sheetGrid);
    // Inspected here, on the one path both a fresh sheet and recovered saved pixels go through, so a
    // sheet rejected for what it drew cannot come back through the recovery below unexamined.
    await inspectOrThrow({
      kind: "clips", character: layer.name, face: source.face, sheet: { ...grid, count: frameCount },
      image: { bytes, mimeType: "image/png" },
    });
    return { bytes, repaired: bytes !== original, registered };
  };
  let prepared: Awaited<ReturnType<typeof prepare>> | undefined;
  // Older attempts may have rejected an intact sheet solely for drifting across the grid.
  // Try the saved pixels before buying another image; missing face markers still require redraw.
  const db = await getDatabase();
  const existing = await db.select().from(assets).where(eq(assets.id, ids.raw)).then(firstRow);
  if (existing?.state === "failed" && existing.ownerId === job.ownerId && existing.stickerId === stickerId) {
    const saved = await getObjectStore().get(existing.r2Key);
    try { prepared = await prepare(saved.bytes); }
    catch { /* Not recoverable: generate a replacement below. */ }
  }
  const recoveredSavedSheet = Boolean(prepared);
  // A sheet the inspector rejects is bought once more with its problems in the prompt; a sheet the
  // pixel gates reject is not, because those failures say the model ignored the layout, and the
  // turn's Retry button is the right place to pay for that again.
  let feedback: string[] | undefined;
  for (let attempt = 0; !prepared; attempt += 1) {
    await generateAndStoreAsset(job, stickerId, {
      assetId: ids.raw, references, mode: "conversation_edit", keepFrame: true, quality: "medium",
      sheet: { ...grid, count: frameCount, facePlaceholder: true, faceRegion: source.face },
      sequence: { ...grid, frameCount, frameRate: frameCount / durationSeconds },
      prompt: spriteClipPrompt(layer, source, clip, references.length > 2, feedback),
    });
    try {
      const raw = await getObjectStore().get(objectKey(job.ownerId, ids.raw, "image/png"));
      prepared = await prepare(raw.bytes);
    } catch (error) {
      await discardSheet(ids.raw);
      if (error instanceof SheetRejected && attempt === 0) {
        feedback = error.problems;
        await reportTurnNote(job, "Redrawing the sheet with the reviewer's notes");
        continue;
      }
      throw error;
    }
  }
  const metadata = { ...sheetGrid, frameRate: frameCount / durationSeconds, durationSeconds };
  if (prepared.repaired || recoveredSavedSheet) {
    await storeSheetAsset(job, stickerId, ids.raw, prepared.bytes, metadata, true);
  }
  const { registered } = prepared;
  await storeSheetAsset(job, stickerId, ids.clean, registered.bytes, metadata, true);
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
  // Show the exact opening, including its surrounding head, instead of asking the model to
  // infer a face patch from full-character references (which can produce a miniature head).
  const firstClip = source.clips[0];
  const clipGrid = spriteSheetGrid(firstClip.frames.length);
  const rawId = spriteClipAssetIds(assetJobId, layer.layerId, firstClip.id).raw;
  const raw = await getObjectStore().get(objectKey(job.ownerId, rawId, "image/png"));
  const metadata = await sharp(raw.bytes).metadata();
  const guide = await sharp(raw.bytes).extract({
    left: 0, top: 0,
    width: Math.floor(metadata.width! / clipGrid.columns),
    height: Math.floor(metadata.height! / clipGrid.rows),
  }).png().toBuffer();
  // Same one-redraw rule as `buildClip`: only the inspector's rejection earns a second sheet.
  let feedback: string[] | undefined;
  for (let attempt = 0; ; attempt += 1) {
    await generateAndStoreAsset(job, stickerId, {
      assetId, references: [...references, { bytes: guide, mimeType: "image/png" }],
      mode: "conversation_edit", keepFrame: true, quality: "medium",
      sheet: { ...grid, count, tiles: true, faceRegion: source.face },
      sequence: { ...grid, frameCount: count, frameRate: 1 },
      prompt: spriteExpressionPrompt(layer, source, references.length > 2, feedback),
    });
    const sheet = await getObjectStore().get(objectKey(job.ownerId, assetId, "image/png"));
    try {
      await validateGeneratedAtlas(sheet.bytes, { ...grid, frameCount: count });
      const tiles = await registerExpressionTiles(sheet.bytes, { ...grid, frameCount: count });
      await inspectOrThrow({
        kind: "expressions", character: layer.name, face: source.face, sheet: { ...grid, count },
        image: { bytes: sheet.bytes, mimeType: "image/png" }, expressions: source.expressions.map((expression) => expression.label),
      });
      return { assetId, ...grid, tiles: tiles.map((tile, index) => ({ id: source.expressions[index].id, ...tile })) };
    } catch (error) {
      await discardSheet(assetId);
      if (error instanceof SheetRejected && attempt === 0) {
        feedback = error.problems;
        await reportTurnNote(job, "Redrawing the faces with the reviewer's notes");
        continue;
      }
      throw error;
    }
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
  animationSummary?: Reference,
): Promise<Map<string, SpriteBuild>> {
  const builds = new Map<string, SpriteBuild>();
  const sprites = planSpriteLayers(plan);
  if (sprites.length === 0) return builds;
  if (!reference) throw new Error("A sprite character needs the approved static reference");
  const db = await getDatabase();
  const store = getObjectStore();
  const stills = new Map(generatedLayers(plan, assetJobId).map((item) => [item.layer.layerId, item.assetId]));
  const completed = await completedBuildSteps(job);
  const total = sprites.reduce((sum, { source }) => sum + source.clips.length + 1, 0);
  const clipCheckpoints = new Map<string, SpriteBuild["clips"][number]>();
  const expressionCheckpoints = new Map<string, SpriteBuild["expressions"]>();
  const reusedKeys = new Set<string>();
  for (const { layer, source } of sprites) {
    for (const clip of source.clips) {
      const key = `sprite-clip:${layer.layerId}:${clip.id}`;
      const cached = await loadBuildCheckpoint(job, assetJobId, key, SpriteClipV1Schema);
      const ids = spriteClipAssetIds(assetJobId, layer.layerId, clip.id);
      if (cached && await buildAssetsReady(job, [cached.assetId])) {
        clipCheckpoints.set(key, cached);
        reusedKeys.add(key);
      } else if (completed.has(`compose-sprite ${layer.name} ${clip.id}`)
        && await buildAssetsReady(job, [ids.raw, ids.clean])) reusedKeys.add(key);
    }
    const key = `sprite-expressions:${layer.layerId}`;
    const cached = await loadBuildCheckpoint(job, assetJobId, key, SpriteExpressionsV1Schema);
    if (cached && await buildAssetsReady(job, [cached.assetId])) {
      expressionCheckpoints.set(key, cached);
      reusedKeys.add(key);
    } else if (completed.has(`compose-sprite ${layer.name} expressions`)
      && await buildAssetsReady(job, [spriteExpressionAssetId(assetJobId, layer.layerId)])) reusedKeys.add(key);
  }
  let done = reusedKeys.size;
  if (done < total) await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "composing_sprite", message: "Composing sprite sheets…",
    progressLabel: "Sprite sheets", completedUnits: done, totalUnits: total,
  });
  const progress = async (partName: string) => {
    done += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_sprite", progress: 0.05 + 0.7 * (done / total), partName, sheetIndex: done - 1, sheetCount: total,
      progressLabel: "Sprite sheets", completedUnits: done, totalUnits: total,
    });
  };

  for (const { layer, source } of sprites) {
    const stillId = stills.get(layer.layerId);
    if (!stillId) throw new Error(`Sprite layer ${layer.layerId} has no separated still`);
    const [stillRow] = await getReadyOwnedAssets(db, job.ownerId, [stillId]);
    const still = { bytes: (await store.get(stillRow.r2Key)).bytes, mimeType: stillRow.mimeType };
    const references = [reference, still, ...(animationSummary ? [animationSummary] : [])];

    const clips: SpriteBuild["clips"] = [];
    for (const clip of source.clips) {
      await assertJobStillRunning(job.id);
      const key = `sprite-clip:${layer.layerId}:${clip.id}`;
      const cached = clipCheckpoints.get(key);
      if (cached) {
        clips.push(cached);
        continue;
      }
      const label = `compose-sprite ${layer.name} ${clip.id}`;
      const reused = reusedKeys.has(key);
      const call = reused ? undefined : await beginToolCall(job, "build-plan", undefined, label);
      try {
        const built = await buildClip(job, stickerId, assetJobId, layer, source, clip, references);
        await saveBuildCheckpoint(job, assetJobId, key, built);
        clips.push(built);
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
      await finishToolCall(job, call, "complete", { previewAssetId: clips.at(-1)!.assetId });
      if (!reused) await progress(`${layer.name} ${clip.label}`);
    }

    await assertJobStillRunning(job.id);
    const expressionKey = `sprite-expressions:${layer.layerId}`;
    const cached = expressionCheckpoints.get(expressionKey);
    let expressions: SpriteBuild["expressions"];
    if (cached) {
      expressions = cached;
    } else {
      const label = `compose-sprite ${layer.name} expressions`;
      const reused = reusedKeys.has(expressionKey);
      const call = reused ? undefined : await beginToolCall(job, "build-plan", undefined, label);
      try {
        expressions = await buildExpressions(job, stickerId, assetJobId, layer, source, references);
        await saveBuildCheckpoint(job, assetJobId, expressionKey, expressions);
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
      await finishToolCall(job, call, "complete", { previewAssetId: expressions.assetId });
      if (!reused) await progress(`${layer.name} expressions`);
    }

    const posterAssetId = await ensureSpritePoster(db, job.ownerId, stickerId, {
      clip: clips[0], expressions: { assetId: expressions.assetId }, tile: expressions.tiles[0],
    });
    builds.set(layer.layerId, { clips, expressions, posterAssetId });
  }
  return builds;
}
