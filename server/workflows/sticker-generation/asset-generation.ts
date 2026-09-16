// Turning a model's answer into stored artwork: the image and video generations, the subject
// measurement kept beside them, and the document a plan's layers assemble into.

import { and, eq } from "drizzle-orm";
import { FatalError } from "workflow";
import sharp from "sharp";
import { configurationFromPlan } from "./configurable-artwork";
import { preferredChromaKey, type ChromaKeyColor } from "@/lib/ai/chroma-key";
import { compilePlanAnimations, planLayerAnchor, type PlanV1 } from "@/lib/contracts/plan";
import { applyStickerOperationsV1, CURRENT_DOCUMENT_VERSION, DOCUMENT_DURATION_SECONDS, StickerDocumentSchema, type StickerDocument, type StickerLayerV1 } from "@/lib/contracts/sticker";
import { DEFAULT_ANCHOR } from "@/lib/contracts/animation";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, generationJobs, stickers } from "@/lib/db/schema";
import { getAiProvider, type AiImageReferenceCandidate } from "@/lib/ai/gateway";
import { clampLayoutOnCanvas } from "@/lib/layout/composition";
import { suggestFreePlacement } from "@/lib/layout/placement";
import { SubjectBoundsSchema, type SubjectBounds } from "@/lib/images/subject-bounds";
import { describeError, traceEvent, traceSpan } from "@/lib/observability/trace";
import { derivedAssetId } from "@/lib/services/assets";
import { getObjectStore, inspectImage, inspectMp4, objectKey, type ObjectStore } from "@/lib/storage/r2";
import { isAbortError, reportTurnNote } from "./turn-context";

export async function loadStoredGeneratedImage(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  assetId: string,
): Promise<{ subject?: SubjectBounds } | undefined> {
  const stored = await (await getDatabase()).select().from(assets).where(and(
    eq(assets.id, assetId),
    eq(assets.ownerId, job.ownerId),
    eq(assets.stickerId, stickerId),
    eq(assets.state, "ready"),
  )).then(firstRow);
  if (!stored) return undefined;
  return { subject: await storedSubjectBounds(getObjectStore(), stored.r2Key) };
}

export async function generateAndStoreAsset(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  params: {
    assetId: string;
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
    mask?: { bytes: Uint8Array; mimeType: string };
    conversationContext?: string;
    mode: "generate" | "conversation_edit";
    isolatedLayer?: boolean;
    /**
     * A complete static plan reference rather than one separated sticker part. References are
     * deliberately opaque, so they skip the transparency gate and land as a `preview` asset.
     */
    concept?: boolean;
    conceptPurpose?: "animation-summary";
    keepFrame?: boolean;
    sequence?: { columns: number; rows: number; frameCount: number; frameRate: number };
    /** Ask the model for a sprite sheet rather than one subject. See `AiImageInput.sheet`. */
    sheet?: { columns: number; rows: number; count: number; facePlaceholder?: boolean; tiles?: boolean; faceRegion?: string };
    quality?: "low" | "medium" | "high";
  },
): Promise<{ subject?: SubjectBounds }> {
  const db = await getDatabase();
  const objectStore = getObjectStore();
  const provider = getAiProvider();
  // A timed-out generation is the one failure the step must not hand back to the runtime: retrying
  // it starts another multi-minute image from scratch, and since the deadline is the same the retry
  // times out too. The turn just sits on "Running…" while each attempt is billed. Fail it once and
  // let the user decide, which is what the transcript's Retry button is for.
  const trace = {
    jobId: job.id,
    assetId: params.assetId,
    mode: params.concept ? "concept" : params.mode,
    references: params.references.length,
    masked: Boolean(params.mask),
    quick: job.quick,
  };
  // Every failure after this point replays the whole step, so a turn that dies late pays for the same
  // picture again on each attempt. The id is derived from the job, so an image already stored under it
  // was produced by this turn from this prompt: take it instead of buying a second copy.
  const stored = await loadStoredGeneratedImage(job, stickerId, params.assetId);
  if (stored) {
    traceEvent("generateImage:reused", trace);
    await reportTurnNote(job, "Reusing artwork from the last attempt");
    // The measurement was taken from the frame the model returned, which is gone: the stored master
    // is the crop. It was written next to the object for exactly this replay.
    return stored;
  }
  await reportTurnNote(job, imageNote(params));
  const generated = await traceSpan("generateImage", trace, () => params.concept
    ? provider.generateConceptImage({ prompt: params.prompt, references: params.references, purpose: params.conceptPurpose })
    : provider.generateStickerImage({
      prompt: params.prompt,
      references: params.references,
      mask: params.mask,
      conversationContext: params.conversationContext,
      mode: params.mode,
      isolatedLayer: params.isolatedLayer,
      keepFrame: params.keepFrame,
      sheet: params.sheet,
      quality: params.quality,
      // Read off the job rather than passed down through every call site, because it is a property
      // of the turn: whatever a quick turn ends up drawing — one sticker, or each separated part of
      // a composed one — is drawn by the same model. The concept branch above is deliberately left
      // on the main model: a plan reference is opaque by design, so there is no background to key,
      // and a quick turn only reaches it in the rare case where the agent decides to plan first.
      quick: job.quick,
    })).catch((error: unknown) => {
    if (!isAbortError(error)) throw error;
    throw new FatalError("Image generation took too long to finish. Try that request again.");
  });
  const currentJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).then(firstRow);
  const currentSticker = await db.select({ status: stickers.status }).from(stickers).where(eq(stickers.id, stickerId)).then(firstRow);
  if (currentJob?.state !== "running" || !currentSticker || currentSticker.status === "deleting") {
    // The image exists and is about to be thrown away. Worth a line of its own: from the outside
    // this is indistinguishable from a generation that never happened, and the bill says otherwise.
    traceEvent("generateImage:discarded", {
      ...trace,
      jobState: currentJob?.state,
      stickerStatus: currentSticker?.status,
    });
    throw new Error("Generation was cancelled before storage");
  }
  const inspection = await inspectImage(generated.bytes);
  traceEvent("generateImage:inspected", {
    ...trace,
    bytes: inspection.byteSize,
    width: inspection.width,
    height: inspection.height,
    hasAlpha: inspection.hasTransparentPixels,
  });
  if (inspection.width !== 1024 || inspection.height !== 1024) {
    throw new Error("Generated candidate failed normalized size validation");
  }
  if (!params.concept && !inspection.hasTransparentPixels) {
    throw new Error("Generated candidate failed normalized transparency validation");
  }
  const r2Key = objectKey(job.ownerId, params.assetId, "image/png");
  await traceSpan("storeImage", { ...trace, r2Key }, () => objectStore.put(r2Key, {
    bytes: generated.bytes,
    contentType: "image/png",
    metadata: {
      sha256: inspection.sha256,
      source: "vercel-ai-gateway",
      ...(generated.subject ? { subject: JSON.stringify(generated.subject) } : {}),
    },
  }));
  const afterPutJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).then(firstRow);
  if (afterPutJob?.state !== "running") {
    await objectStore.delete(r2Key);
    throw new Error("Generation was cancelled during storage");
  }
  try {
    await db.insert(assets).values({
      id: params.assetId,
      ownerId: job.ownerId,
      stickerId,
      kind: params.concept ? "preview" : params.sequence ? "sequence" : "master",
      ...(params.sequence ? { sequenceColumns: params.sequence.columns, sequenceRows: params.sequence.rows, frameCount: params.sequence.frameCount, fps: params.sequence.frameRate, durationSeconds: params.sequence.frameCount / params.sequence.frameRate } : {}),
      state: "ready",
      r2Key,
      mimeType: "image/png",
      byteSize: inspection.byteSize,
      width: inspection.width,
      height: inspection.height,
      sha256: inspection.sha256,
      hasAlpha: inspection.hasTransparentPixels,
      createdAt: new Date(),
      readyAt: new Date(),
    }).onConflictDoUpdate({
      target: assets.id,
      set: {
        state: "ready",
        byteSize: inspection.byteSize,
        width: inspection.width,
        height: inspection.height,
        sha256: inspection.sha256,
        hasAlpha: inspection.hasTransparentPixels,
        readyAt: new Date(),
      },
    });
  } catch (error) {
    await objectStore.delete(r2Key);
    throw error;
  }
  traceEvent("generateImage:stored", trace);
  await reportTurnNote(job, params.concept ? "Saved the sketch" : "Saved the artwork");
  return { subject: generated.subject };
}

/**
 * What to call the picture about to be drawn.
 *
 * Written from the request rather than from `mode`, whose words ("conversation_edit") are the
 * pipeline's, not the user's. A reference count is worth saying because it is the difference
 * between the model working from the sticker on screen and working from nothing.
 */
function imageNote(params: {
  conceptPurpose?: "animation-summary";
  references: ReadonlyArray<unknown>;
  mask?: unknown;
  concept?: boolean;
  sheet?: unknown;
  sequence?: unknown;
  mode: "generate" | "conversation_edit";
}): string {
  if (params.conceptPurpose === "animation-summary") return "Illustrating the animation plan";
  if (params.concept) return "Sketching the concept";
  if (params.sheet || params.sequence) return "Drawing the frames";
  if (params.mask) return "Redrawing the painted area";
  const base = params.mode === "conversation_edit" ? "Redrawing the artwork" : "Drawing the artwork";
  if (params.references.length === 0) return base;
  return params.references.length === 1
    ? `${base} from 1 reference`
    : `${base} from ${params.references.length} references`;
}

/** The subject measurement written beside a stored master, or nothing for one stored without it. */
async function storedSubjectBounds(objectStore: ObjectStore, r2Key: string): Promise<SubjectBounds | undefined> {
  try {
    const raw = (await objectStore.head(r2Key)).metadata?.subject;
    return raw ? SubjectBoundsSchema.parse(JSON.parse(raw)) : undefined;
  } catch (error) {
    // Older objects, or a store that dropped the metadata: the plan's own layout still applies.
    traceEvent("generateImage:subjectUnavailable", { r2Key, error: describeError(error) });
    return undefined;
  }
}

/**
 * Lets the orchestration model inspect lightweight previews and choose the full-resolution
 * references for one image-model call. Required source pixels (an edit target or approved plan)
 * are unioned back in defensively, so a malformed provider answer cannot turn an edit into a
 * redesign.
 */
export async function selectImageReferences(
  instruction: string,
  history: string,
  candidates: AiImageReferenceCandidate[],
  quick = false,
): Promise<Array<{ bytes: Uint8Array; mimeType: string }>> {
  const bounded = candidates.slice(0, 8);
  if (bounded.length === 0) return [];
  if (bounded.every((candidate) => candidate.required)) {
    // Nothing to choose. A required candidate is passed to the image model whatever the selector
    // says — the union below puts it back — so a list with no optional images has exactly one
    // possible answer, and asking for it costs a vision call on the orchestrator model (measured at
    // 2-3s) to be told what was already decided. This is the common shape of an ordinary edit: the
    // artwork being changed is required, and the user attached nothing to it.
    traceEvent("selectImageReferences:decided", { candidates: bounded.length });
    return bounded.map((candidate) => candidate.image);
  }
  if (quick) {
    // The selector is a vision call on the orchestrator model, and it exists to protect a very
    // expensive draw from being handed the wrong pictures. A quick draw is not expensive, and this
    // deliberation costs more wall clock than the drawing it is deliberating about — so the quick
    // path takes every candidate, which is the answer the selector almost always gives anyway once
    // the list is already capped at eight.
    traceEvent("selectImageReferences:quick", { candidates: bounded.length });
    return bounded.map((candidate) => candidate.image);
  }
  const selected = await getAiProvider().selectImageReferences({
    instruction,
    history,
    candidates: bounded,
    maxReferences: 8,
  });
  const required = bounded
    .map((candidate, index) => (candidate.required ? index : -1))
    .filter((index) => index >= 0);
  return [...new Set([...required, ...selected])]
    .map((index) => bounded[index]?.image)
    .filter((image): image is { bytes: Uint8Array; mimeType: string } => Boolean(image))
    .slice(0, 8);
}

/** Wraps layers in the canonical canvas and per-kind default timing. */
function documentWithLayers(kind: "static" | "animated", layers: unknown[]): StickerDocument {
  const base = {
    version: CURRENT_DOCUMENT_VERSION,
    canvas: { width: 1024, height: 1024, coordinateSpace: "normalized" as const, transparent: true },
    mp4Background: { type: "solid" as const, color: "#FFFFFF" },
    layers,
  };
  return kind === "static"
    ? StickerDocumentSchema.parse({ ...base, kind, durationSeconds: 0, fps: 0, loop: "once" })
    : StickerDocumentSchema.parse({ ...base, kind, durationSeconds: 2, fps: 30, loop: "loop" });
}

/**
 * Appends a drawn layer on top of the stack, in the free canvas rather than over the middle.
 *
 * The no-loop path has no model choosing a spot, so the spot is chosen here the way the edit loop
 * chooses one for a model that stayed silent: the largest place that covers nothing.
 */
export function addLayerBesideExisting(document: StickerDocument, layer: StickerLayerV1): StickerDocument {
  const placement = suggestFreePlacement(document);
  return clampLayoutOnCanvas(applyStickerOperationsV1(document, [
    { op: "addLayer", layer },
    { op: "setLayerAnimations", layerId: layer.id, animations: [], anchor: { ...DEFAULT_ANCHOR, ...placement } },
  ]));
}

export function emptyDocument(kind: "static" | "animated", assetId: string): StickerDocument {
  return documentWithLayers(kind, [{
    id: "hero",
    name: "Hero",
    hidden: false,
    type: "image" as const,
    assetId,
    contentMode: "fit" as const,
    animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [] },
  }]);
}

/**
 * The generate-backed layers of a plan, paired with the deterministic asset id each one will use.
 *
 * Indexes are assigned over generate layers only, so inserting a text layer ahead of an image layer
 * does not shift every asset id and orphan the objects a replay already wrote to R2.
 */
export function generatedLayers(plan: PlanV1, jobId: string) {
  let index = 0;
  return plan.layers.flatMap((layer): GeneratedLayer[] => {
    if (layer.source.kind === "generate") {
      return [{ layer, prompt: layer.source.prompt, assetId: derivedAssetId(jobId, index++) }];
    }
    // A sprite's still is separated from the approved reference exactly like a part: it is what
    // every clip sheet is drawn from, and what the expression sheet copies the face of.
    if (layer.source.kind === "sprite") {
      return [{ layer, prompt: layer.source.prompt, assetId: derivedAssetId(jobId, index++) }];
    }
    if (layer.source.kind === "video") {
      // The clip's still shares the generate index space, so its poster is stored and replayed
      // exactly like any other part. The clip and its scratch backdrop get their own slots, named
      // rather than numbered so they can never collide with a still's.
      const slot = index++;
      return [{
        layer,
        prompt: layer.source.prompt,
        assetId: derivedAssetId(jobId, slot),
        video: {
          motion: layer.source.motion,
          durationSeconds: layer.source.durationSeconds,
          keyColor: preferredChromaKey(layer.source.prompt),
          assetId: derivedAssetId(jobId, `video:${slot}`),
          backdropAssetId: derivedAssetId(jobId, `video-backdrop:${slot}`),
        },
      }];
    }
    return [];
  });
}

interface GeneratedLayer {
  layer: PlanV1["layers"][number];
  prompt: string;
  /** The transparent still: the part itself, or the poster a clip is animated from. */
  assetId: string;
  /** Present for a `video` source: what to animate the still into, and where to store the clip. */
  video?: VideoGeneration;
}

/**
 * Everything a built sprite layer needs that the plan could not know: which sheets were stored,
 * where the face slot landed in every frame, and the poster. Produced by
 * `workflows/sticker-generation/sprite-artwork.ts`, consumed by `documentFromPlan`.
 */
export interface SpriteBuild {
  clips: Array<{
    id: string;
    assetId: string;
    columns: number;
    rows: number;
    frames: Array<{ duration: number; faceX: number; faceY: number; faceSize: number }>;
  }>;
  expressions: {
    assetId: string;
    columns: number;
    rows: number;
    tiles: Array<{ id: string; x: number; y: number; width: number; height: number }>;
  };
  posterAssetId: string;
}

/**
 * One clip to buy: what the subject does, which screen it is shot against, and where it lands.
 *
 * Named rather than left inline on `GeneratedLayer` because plans are no longer the only thing that
 * orders a clip — the edit loop's `create_video` builds one of these from a layer the sticker
 * already has, and the two paths share every step from the flatten onwards.
 */
interface VideoGeneration {
  motion: string;
  durationSeconds: number;
  keyColor: ChromaKeyColor;
  assetId: string;
  backdropAssetId: string;
}

/** What `documentFromPlan` needs to know about a clip that has already been stored. */
export interface StoredVideoTiming {
  frameCount: number;
  fps: number;
  durationSeconds: number;
}

/**
 * Animates a stored still into a clip and stores it as a ready `video` asset.
 *
 * The still is the transparent part `generateAndStoreAsset` just produced. The video model cannot
 * take alpha, so it is flattened onto the key colour first; that flattened copy is a scratch
 * object, presigned for the provider and deleted afterwards, never an asset row. The same guards
 * apply as for an image: a stored clip is reused on replay, a timed-out generation is final, and a
 * turn that was cancelled while the clip was in flight throws the clip away rather than storing it.
 */
export async function generateAndStoreVideoAsset(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  input: { stillAssetId: string; video: VideoGeneration },
): Promise<StoredVideoTiming> {
  const db = await getDatabase();
  const objectStore = getObjectStore();
  const provider = getAiProvider();
  const { video } = input;
  const trace = {
    jobId: job.id,
    assetId: video.assetId,
    stillAssetId: input.stillAssetId,
    durationSeconds: video.durationSeconds,
    keyColor: video.keyColor.name,
  };
  const stored = await db.select({
    state: assets.state,
    frameCount: assets.frameCount,
    fps: assets.fps,
    durationSeconds: assets.durationSeconds,
  }).from(assets).where(and(
    eq(assets.id, video.assetId),
    eq(assets.ownerId, job.ownerId),
    eq(assets.stickerId, stickerId),
  )).then(firstRow);
  if (stored?.state === "ready" && stored.frameCount && stored.fps && stored.durationSeconds) {
    traceEvent("generateVideo:reused", trace);
    await reportTurnNote(job, "Reusing the clip from the last attempt");
    return { frameCount: stored.frameCount, fps: stored.fps, durationSeconds: stored.durationSeconds };
  }

  const still = await objectStore.get(objectKey(job.ownerId, input.stillAssetId, "image/png"));
  const backdropKey = objectKey(job.ownerId, video.backdropAssetId, "image/png");
  const r2Key = objectKey(job.ownerId, video.assetId, "video/mp4");
  try {
    const flattened = await sharp(still.bytes).flatten({ background: video.keyColor.hex }).png().toBuffer();
    await objectStore.put(backdropKey, { bytes: new Uint8Array(flattened), contentType: "image/png" });
    // Fifteen minutes: the provider queues the request before it fetches the frame, and a link that
    // expired in the queue fails the clip with an error that looks like a bad image.
    const { url } = await objectStore.signedGet(backdropKey, undefined, 900);

    await reportTurnNote(job, "Filming the clip");
    const generated = await traceSpan("generateVideo", trace, () => provider.generateStickerVideo({
      imageUrl: url,
      motion: video.motion,
      durationSeconds: video.durationSeconds,
      keyColor: video.keyColor,
    })).catch((error: unknown) => {
      if (!isAbortError(error)) throw error;
      throw new FatalError("Video generation took too long to finish. Try that request again.");
    });

    const currentJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).then(firstRow);
    const currentSticker = await db.select({ status: stickers.status }).from(stickers).where(eq(stickers.id, stickerId)).then(firstRow);
    if (currentJob?.state !== "running" || !currentSticker || currentSticker.status === "deleting") {
      traceEvent("generateVideo:discarded", { ...trace, jobState: currentJob?.state, stickerStatus: currentSticker?.status });
      throw new Error("Generation was cancelled before storage");
    }

    const inspection = inspectMp4(generated.bytes);
    traceEvent("generateVideo:inspected", {
      ...trace,
      model: generated.modelId,
      bytes: inspection.byteSize,
      width: inspection.width,
      height: inspection.height,
      frameCount: inspection.frameCount,
      fps: inspection.fps,
      clipSeconds: inspection.durationSeconds,
    });
    if (inspection.width !== inspection.height) {
      throw new Error("Generated clip is not square");
    }

    await traceSpan("storeVideo", { ...trace, r2Key }, () => objectStore.put(r2Key, {
      bytes: generated.bytes,
      contentType: "video/mp4",
      metadata: { sha256: inspection.sha256, source: "vercel-ai-gateway", model: generated.modelId },
    }));
    const afterPutJob = await db.select({ state: generationJobs.state }).from(generationJobs).where(eq(generationJobs.id, job.id)).then(firstRow);
    if (afterPutJob?.state !== "running") {
      await objectStore.delete(r2Key);
      throw new Error("Generation was cancelled during storage");
    }
    const timing = {
      frameCount: inspection.frameCount,
      fps: inspection.fps,
      durationSeconds: inspection.durationSeconds,
    };
    try {
      await db.insert(assets).values({
        id: video.assetId,
        ownerId: job.ownerId,
        stickerId,
        kind: "video",
        state: "ready",
        r2Key,
        mimeType: "video/mp4",
        byteSize: inspection.byteSize,
        width: inspection.width,
        height: inspection.height,
        ...timing,
        sha256: inspection.sha256,
        hasAlpha: false,
        createdAt: new Date(),
        readyAt: new Date(),
      }).onConflictDoUpdate({
        target: assets.id,
        set: {
          state: "ready",
          byteSize: inspection.byteSize,
          width: inspection.width,
          height: inspection.height,
          ...timing,
          sha256: inspection.sha256,
          readyAt: new Date(),
        },
      });
    } catch (error) {
      await objectStore.delete(r2Key);
      throw error;
    }
    return timing;
  } finally {
    // Scratch, not an asset: nothing references it once the provider has fetched it.
    await objectStore.delete(backdropKey).catch((error: unknown) => {
      traceEvent("generateVideo:backdropSweepFailed", { ...trace, error: describeError(error) });
    });
  }
}

/**
 * Turns a confirmed plan into a multi-layer document.
 *
 * Layout is expressed through each layer's `anchor`, which the compiler turns into a single
 * keyframe at t=0 on whichever channels differ from the renderer's defaults: the interpolator
 * returns a constant when a channel has one keyframe, and static documents are only allowed
 * keyframes at t=0, so this is the one encoding that works for both kinds.
 */
export function documentFromPlan(
  plan: PlanV1,
  jobId: string,
  /** Timing of every stored clip, by plan layer id. Required for each `video` source. */
  videoTimings: ReadonlyMap<string, StoredVideoTiming> = new Map(),
  /** The registered sheets of every sprite, by plan layer id. Required for each `sprite` source. */
  spriteBuilds: ReadonlyMap<string, SpriteBuild> = new Map(),
): StickerDocument {
  const compiled = compilePlanAnimations(plan);
  const generated = generatedLayers(plan, jobId);
  const assetIds = new Map(generated.map((item) => [item.layer.layerId, item.assetId]));
  const videoIds = new Map(generated.flatMap((item) => (item.video ? [[item.layer.layerId, item.video] as const] : [])));

  const layers = plan.layers.map((layer, index): StickerLayerV1 => {
    const base = {
      id: layer.layerId,
      name: layer.name,
      hidden: false,
      anchor: planLayerAnchor(layer),
      animations: layer.animations,
      animation: compiled[index],
      blendMode: "normal" as const,
    };
    const source = layer.source;
    // The plan vocabulary stays deliberately narrow — a planner picks a colour, not a gradient —
    // so each planned colour becomes a solid paint here. Richer paints exist for the editor to
    // author; widening the plan would only give the model more ways to be wrong.
    const solid = (color: string) => ({ type: "solid" as const, color });
    switch (source.kind) {
    case "generate":
      return { ...base, type: "image", assetId: assetIds.get(layer.layerId)!, contentMode: "fit" };
    // Reused artwork is an ordinary image layer pointing at an asset an earlier turn already paid
    // for. It is indistinguishable from a generated one here on purpose: what a plan changes about
    // a layer it keeps — where it sits, how it moves — is authored the same way either way.
    case "existing":
      return { ...base, type: "image", assetId: source.assetId, contentMode: "fit" };
    case "text":
      return {
        ...base,
        type: "text",
        text: source.text,
        font: source.font,
        weight: source.weight,
        paint: solid(source.color),
        alignment: source.alignment,
      };
    case "shape":
      return {
        ...base,
        type: "shape",
        shape: source.shape === "star" ? { kind: "star", points: 5, innerRatio: 0.42 } : { kind: source.shape },
        fill: solid(source.fill),
        // A zero width is v1's way of saying "no stroke", and the plan schema kept that shape.
        stroke: source.stroke && source.strokeWidth > 0
          ? { paint: solid(source.stroke), width: source.strokeWidth, lineCap: "round", lineJoin: "round", dash: [] }
          : undefined,
        cornerRadius: source.cornerRadius,
      };
    case "particle":
      return {
        ...base,
        type: "particle",
        preset: source.preset,
        count: source.count,
        paint: solid(source.color),
        seed: source.seed,
      };
    // Captured footage carries straight through: the grid was fixed when the atlas was encoded on
    // device, and nothing here is allowed to reinterpret it. `posterAssetId` is filled in later, by
    // `ensureSequencePosters`, on the way into the revision.
    case "sequence":
      return {
        ...base,
        type: "sequence",
        assetId: source.assetId,
        columns: source.columns,
        rows: source.rows,
        frameCount: source.frameCount,
        frameRate: source.frameRate,
        playback: source.playback,
        startSeconds: 0,
        contentMode: "fit",
      };
    // The clip plays from the top of the timeline and repeats; its poster is the still it was
    // animated from, which is what everything that cannot decode video draws in its place.
    case "video": {
      const video = videoIds.get(layer.layerId);
      const timing = videoTimings.get(layer.layerId);
      if (!video || !timing) throw new Error(`Video layer ${layer.layerId} has no stored clip`);
      return {
        ...base,
        type: "video",
        assetId: video.assetId,
        keyColor: video.keyColor.name,
        frameCount: timing.frameCount,
        frameRate: timing.fps,
        playback: "loop",
        startSeconds: 0,
        contentMode: "fit",
        posterAssetId: assetIds.get(layer.layerId)!,
      };
    }
    // The clips and faces come from the build; the defaults are the plan's first entries, which the
    // planner is told to make the idle clip and the neutral face.
    case "sprite": {
      const build = spriteBuilds.get(layer.layerId);
      if (!build) throw new Error(`Sprite layer ${layer.layerId} has no registered sheets`);
      return {
        ...base,
        type: "sprite",
        clips: build.clips,
        expressions: build.expressions,
        clipId: source.clips[0].id,
        expressionId: source.expressions[0].id,
        contentMode: "fit",
        posterAssetId: build.posterAssetId,
      };
    }
    }
  });

  const canvas = { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true } as const;
  // The document must sample at least as fast as the fastest capture in it, or the contract refuses
  // the document outright — and a plan the user already confirmed would fail at build time with an
  // error about frame rates. Raising the fps is both the fix and what the user meant: they asked for
  // their footage, not for a slower version of it. A clip is footage too, and the same goes for its
  // length: a turnaround cut off before it comes round is not the motion that was planned.
  const captureRate = Math.max(0, ...plan.layers.map(
    (layer) => (layer.source.kind === "sequence" ? layer.source.frameRate : 0),
  ), ...[...videoTimings.values()].map((timing) => timing.fps));
  // A sprite's longest clip is footage too: the document has to run at least one whole loop of it,
  // and sample fast enough to show its shortest frame.
  const spriteClipSeconds = [...spriteBuilds.values()].flatMap((build) => build.clips.map(
    (clip) => clip.frames.reduce((total, frame) => total + frame.duration, 0),
  ));
  const spriteFrameRate = [...spriteBuilds.values()].flatMap((build) => build.clips.flatMap(
    (clip) => clip.frames.map((frame) => 1 / frame.duration),
  ));
  const clipSeconds = Math.max(0, ...[...videoTimings.values()].map((timing) => timing.durationSeconds), ...spriteClipSeconds);
  return plan.kind === "static"
    ? StickerDocumentSchema.parse({
      version: CURRENT_DOCUMENT_VERSION, canvas, layers, kind: "static", durationSeconds: 0, fps: 0, loop: "once",
    })
    : StickerDocumentSchema.parse({
      version: CURRENT_DOCUMENT_VERSION,
      canvas,
      layers,
      configuration: configurationFromPlan(plan, jobId),
      kind: "animated",
      durationSeconds: Math.min(DOCUMENT_DURATION_SECONDS.max, Math.max(plan.timing.durationSeconds, clipSeconds)),
      fps: Math.min(60, Math.max(plan.timing.fps, Math.ceil(captureRate), ...spriteFrameRate.map(Math.ceil))),
      loop: plan.timing.loop,
    });
}
