import { creationPresetReferences } from "@/lib/creation-presets/references";
// The edit turn: the agent loop that revises an existing sticker, drawing only what the edit
// it chose actually needs.

import { creationPresetGuidance } from "@/lib/creation-presets/selection";
import { and, eq } from "drizzle-orm";
import { chromaKeyForArtwork } from "@/lib/ai/chroma-key";
import { aspectLockedScale, applyStickerOperationsV1, type StickerDocument, type StickerLayerV1, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, generationJobs, stickerRevisions, stickers } from "@/lib/db/schema";
import { getAiProvider, TurnAbort, validateEditOperation, type EditDraftingSession } from "@/lib/ai/gateway";
import { clampLayoutOnCanvas, layoutDiagnostics } from "@/lib/layout/composition";
import { suggestFreePlacement } from "@/lib/layout/placement";
import { traceEvent } from "@/lib/observability/trace";
import { derivedAssetId } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { createCandidateRevision } from "@/lib/services/stickers";
import { getObjectStore } from "@/lib/storage/r2";
import { emptyDocument, generateAndStoreAsset, generateAndStoreVideoAsset, selectImageReferences } from "./asset-generation";
import { assertDocumentAssetsOwned, assertJobStillRunning, beginToolCall, finishToolCall, insertAssistantMessage, renderWorkingDocument, showStickerThroughTool, toolCallLabeller, turnResult } from "./turn-context";
import type { AiTurnResult, StickerToolName } from "./turn-context";

/**
 * How many paid redraws one edit turn may spend.
 *
 * Four is roughly the most a single sentence can honestly have asked for — "redraw the cat and the
 * hat and the badge" is already three — and it bounds what one misread instruction can cost. Past
 * it the tool returns an error telling the model to finish with what it has.
 */
const MAX_EDIT_IMAGE_GENERATIONS = 4;

/**
 * Runs the agent's edit loop and ends the turn with a candidate for the user to keep.
 *
 * This is what "edit the sticker" became once it stopped meaning "redraw one image". The model owns
 * the whole layer stack: it can redraw artwork, draw new artwork, and add, remove, reorder, rename,
 * restyle, and re-lay-out any layer of any type. Most edits never reach an image model at all —
 * removing a caption or resizing a badge is a document operation, which is free and instant.
 *
 * Unlike the animation loop the calls stack rather than restate. An animation update is re-applied
 * to the base document because timing costs nothing to redo; an edit cannot work that way, because
 * by the time the second call arrives the first one has already bought an image.
 */
export async function executeEditTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  sourceMessage: typeof chatMessages.$inferSelect,
  base: StickerDocument,
  activeRevision: typeof stickerRevisions.$inferSelect,
  instruction: string,
  history: string,
  options: {
    targetLayerId?: string;
    imagePlacement: "add" | "replace";
    /** Everything every redraw is shown: the user's attachments, padded with existing artwork. */
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
    /** Leading approved plan references, mandatory when redrawing existing artwork. */
    requiredReferenceCount?: number;
    /** The subset the model itself is shown — only what the user attached this turn. */
    attachedImages: Array<{ bytes: Uint8Array; mimeType: string }>;
    video?: { layerId: string; motion: string; durationSeconds: number };
  },
  toolCallId: string | undefined,
): Promise<AiTurnResult> {
  const db = await getDatabase();
  const objectStore = getObjectStore();
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "planning_edit", progress: 0.25 });

  let working = base;
  /** How many tool calls have changed the document. Zero at the end means the turn is a no-op. */
  let changes = 0;
  let generations = 0;
  /** Clips bought this turn. One is the whole budget; see `createVideoLayer` below. */
  let clips = 0;
  let snapshot = 0;
  const nextLabel = toolCallLabeller();
  // Everything the model did not author: a cancelled job, a vanished asset, a failed generation.
  // Telling it to fix one of those would only spend the loop's step budget, so these stop the loop.
  const abort = (error: unknown): never => { throw new TurnAbort(error); };
  const openCall = async (toolName: StickerToolName): Promise<string> => {
    try {
      return await beginToolCall(job, toolName, undefined, nextLabel(toolName));
    } catch (error) {
      return abort(error);
    }
  };

  /**
   * Applies operations to the working document.
   *
   * Off-canvas is the one layout invariant, and how it is enforced depends on who is paying for the
   * mistake. A free operation is rejected with the same words the layout reviewer gets, so the
   * model can fix its numbers. A drawn image has already been bought, so it is pulled back onto the
   * canvas rather than thrown away with an error.
   */
  const land = async (
    operations: StickerOperationV1[],
    options: { offCanvas: "reject" | "clamp" } = { offCanvas: "reject" },
  ) => {
    await assertJobStillRunning(job.id).catch(abort);
    let document = applyStickerOperationsV1(working, operations);
    const offCanvas = layoutDiagnostics(document).offCanvasLayerIds;
    if (offCanvas.length > 0) {
      if (options.offCanvas === "reject") {
        throw new Error(`Keep every complete layer box on canvas. Fix: ${offCanvas.join(", ")}`);
      }
      document = clampLayoutOnCanvas(document);
    }
    await assertDocumentAssetsOwned(document, job.ownerId, sticker.id).catch(abort);
    working = document;
    changes += 1;
    snapshot += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document }).catch(abort);
    return { revision: changes, document };
  };

  const loadArtwork = async (layer: StickerLayerV1 & { type: "image" }) => {
    const asset = await db.select().from(assets)
      .where(and(eq(assets.id, layer.assetId), eq(assets.ownerId, job.ownerId))).then(firstRow);
    if (!asset || asset.state !== "ready") throw new Error(`Layer ${layer.id} has no readable artwork`);
    const object = await objectStore.get(asset.r2Key);
    return { bytes: object.bytes, mimeType: asset.mimeType };
  };

  /**
   * Draws one image and stores it as a ready master.
   *
   * Every failure in here aborts the loop rather than coming back as advice: a redraw is billed, so
   * inviting the model to try again spends real money re-attempting the same picture.
   */
  const draw = async (prompt: string, source?: StickerLayerV1 & { type: "image" }): Promise<string> => {
    if (generations >= MAX_EDIT_IMAGE_GENERATIONS) {
      throw new Error(
        `This turn has already drawn ${generations} images, which is the limit. `
        + "Finish with finalize_edit, or make the remaining changes with edit_layers.",
      );
    }
    // Slotted by generation count, so a replay that makes the same calls in the same order reuses
    // the images it already paid for instead of buying them a second time.
    const assetId = derivedAssetId(job.id, `edit-${generations}`);
    const artwork = source ? await loadArtwork(source).catch(abort) : undefined;
    // New artwork is composited over the existing sticker. Its image request must not ask the
    // model to rebuild that composition from the chat history or the approved plan.
    const isolatedLayer = !source;
    const selectedReferences = await selectImageReferences(
      isolatedLayer
        ? `Draw only this new isolated overlay element: ${prompt}. Select references only if useful for its style or likeness; do not reproduce the existing sticker or its scenery.`
        : prompt,
      history,
      [
        ...(artwork
          ? [{ label: `current artwork for layer ${source?.name ?? "unknown"}`, image: artwork, required: true }]
          : []),
        ...options.references.map((image, index) => ({
          label: isolatedLayer
            ? `optional style or likeness reference ${index + 1}; do not copy its full composition`
            : index < (options.requiredReferenceCount ?? 0)
            ? "approved plan image"
            : `original or carried reference ${index - (options.requiredReferenceCount ?? 0) + 1}`,
          image,
          required: !isolatedLayer && index < (options.requiredReferenceCount ?? 0),
        })),
      ],
    ).catch(abort);
    await generateAndStoreAsset(job, sticker.id, {
      assetId,
      prompt,
      references: selectedReferences,
      conversationContext: isolatedLayer ? undefined : history,
      mode: artwork ? "conversation_edit" : "generate",
      isolatedLayer,
    }).catch(abort);
    generations += 1;
    return assetId;
  };

  const session: EditDraftingSession = {
    editImageLayer: async ({ layerId, prompt }) => {
      const call = await openCall("edit_image_layer");
      try {
        const layer = working.layers.find((item) => item.id === layerId);
        if (!layer) {
          throw new Error(
            `Unknown layer ${layerId}; the sticker has ${working.layers.map((item) => item.id).join(", ")}`,
          );
        }
        if (layer.type !== "image") {
          throw new Error(
            `Layer ${layerId} is a ${layer.type} layer drawn by the app, so it has no artwork to redraw. `
            + "Change it with edit_layers, or draw a replacement with add_image_layer and remove this one.",
          );
        }
        const assetId = await draw(prompt, layer);
        const state = await land([{ op: "replaceAsset", layerId, assetId }], { offCanvas: "clamp" });
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    addImageLayer: async ({ prompt, name, index, x, y, scaleX, scaleY }) => {
      const call = await openCall("add_image_layer");
      try {
        const assetId = await draw(prompt);
        const layer = emptyDocument(working.kind, assetId).layers[0];
        layer.id = `image_${assetId.replaceAll("-", "").slice(0, 12)}`;
        layer.name = name;
        // Anything the model left unsaid is filled from the free canvas rather than from the
        // centre: a new element dropped at full size over the middle covers whatever was there,
        // which is the one outcome a user asking for "something next to it" never wants.
        const fallback = suggestFreePlacement(working);
        const requested = {
          x: Math.min(1, scaleX ?? fallback.scale.x),
          y: Math.min(1, scaleY ?? fallback.scale.y),
        };
        // Layout goes through setLayerAnimations rather than onto the layer literal: the anchor is
        // only half of a positioned layer, and this is the operation that compiles the other half.
        const anchor = {
          position: { x: x ?? fallback.position.x, y: y ?? fallback.position.y },
          // Square artwork fitted inside its box, the same squaring-off every other write applies.
          scale: aspectLockedScale(requested),
          rotationDegrees: 0,
          opacity: 1,
          trim: { start: 0, end: 1 },
        };
        const state = await land([
          { op: "addLayer", layer, index },
          { op: "setLayerAnimations", layerId: layer.id, animations: [], anchor },
        ], { offCanvas: "clamp" });
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    /**
     * Animates one image layer's own artwork into a clip and swaps the layer over to it.
     *
     * The layer keeps its id, its name, its place in the stack, its anchor and its animations: the
     * only thing that changes is that it plays frames instead of holding one, and its old artwork
     * becomes the poster everything that cannot decode video draws in its place. Doing it as a swap
     * rather than as a new layer is what makes this an edit — the composition the user approved is
     * still standing afterwards, with one part of it moving.
     *
     * Deliberately narrower than the plan path in two ways. One clip per turn, because a clip is the
     * most expensive thing an edit can buy and no sentence asks for two. One clip per sticker,
     * matching the plan's own rule: the client keys each one out at render time, and stacking two of
     * them is a cost and a decode budget nothing has asked for.
     */
    createVideoLayer: async ({ layerId, motion, durationSeconds }) => {
      const call = await openCall("create_video");
      try {
        if (clips > 0) {
          throw new Error(
            "This turn has already made a clip, which is the limit. Finish with finalize_edit.",
          );
        }
        // A clip is frames, and a static document can only ever show the first of them — the
        // contract says so. The project's kind is fixed when it is created, so this is a dead end
        // rather than something to work around, and the tool is not offered on a static sticker.
        if (working.kind !== "animated") {
          throw new Error(
            "This is a static sticker, so it cannot play a clip. Say so rather than trying again.",
          );
        }
        const existing = working.layers.find((item) => item.type === "video");
        if (existing) {
          throw new Error(
            `This sticker already plays a clip on layer ${existing.id}. A sticker holds one; retime `
            + "it with setVideoPlayback, or animate the rest with keyframes.",
          );
        }
        const layer = working.layers.find((item) => item.id === layerId);
        if (!layer) {
          throw new Error(
            `Unknown layer ${layerId}; the sticker has ${working.layers.map((item) => item.id).join(", ")}`,
          );
        }
        if (layer.type !== "image") {
          throw new Error(
            `Layer ${layerId} is a ${layer.type} layer, and a clip is animated from drawn artwork. `
            + "Draw what should move with add_image_layer and make the clip from that layer instead.",
          );
        }
        // Read for the screen colour rather than for the model: the still is flattened onto that
        // colour and keyed back out on the device, so a subject sharing it comes back as a hole.
        // The plan path has to guess this from a prompt; here the pixels themselves decide.
        const artwork = await loadArtwork(layer).catch(abort);
        const keyColor = await chromaKeyForArtwork(artwork.bytes).catch(abort);
        // Slotted by clip count for the same reason images are slotted by generation count: a
        // replayed step re-makes the same call and must find the clip it already paid for.
        const clipAssetId = derivedAssetId(job.id, `edit-video-${clips}`);
        const timing = await generateAndStoreVideoAsset(job, sticker.id, {
          stillAssetId: layer.assetId,
          video: {
            motion,
            durationSeconds,
            keyColor,
            assetId: clipAssetId,
            backdropAssetId: derivedAssetId(job.id, `edit-video-backdrop-${clips}`),
          },
        }).catch(abort);
        clips += 1;
        // Footage carries a frame rate and a length of its own, and a document that samples slower
        // than the clip drops frames — the contract refuses it outright. Raising both is the fix and
        // is what the user meant: they asked for this motion, not for a clipped, stuttering version.
        const retimed = working.fps < timing.fps || working.durationSeconds < timing.durationSeconds
          ? [{
            op: "setTiming" as const,
            // Both bounded by what `setTiming` accepts, which is also what the clip can need: the
            // video model runs at 24 fps and this tool caps a clip at four seconds.
            fps: Math.min(30, Math.max(working.fps, Math.ceil(timing.fps))),
            durationSeconds: Math.min(4, Math.max(working.durationSeconds, timing.durationSeconds)),
            loop: working.loop,
          }]
          : [];
        // Removed and re-inserted at the index it already held, because a layer cannot change its
        // type in place. Everything a `LayerBase` carries comes across verbatim — that is what makes
        // this a swap rather than a new layer landing on top of the composition.
        const state = await land([
          ...retimed,
          { op: "removeLayer", layerId },
          {
            op: "addLayer",
            index: working.layers.indexOf(layer),
            layer: {
              id: layer.id,
              name: layer.name,
              hidden: layer.hidden,
              blendMode: layer.blendMode,
              anchor: layer.anchor,
              animations: layer.animations,
              animation: layer.animation,
              type: "video",
              assetId: clipAssetId,
              // The still it was animated from, kept on: it is what the server, the exports, and
              // any client too old for v4 draw in place of frames they cannot decode.
              posterAssetId: layer.assetId,
              keyColor: keyColor.name,
              frameCount: timing.frameCount,
              frameRate: timing.fps,
              playback: "loop",
              startSeconds: 0,
              contentMode: "fit",
            },
          },
          // Declarative motion carries compiled keyframes that a retime has just invalidated, so it
          // is rebuilt here — the same recompile `setTiming` does for every layer it can. Layers
          // holding hand-authored keyframes are left exactly alone, for the same reason: nothing
          // can rebuild those, and passing an empty spec list would erase them.
          ...(layer.animations.length > 0
            ? [{
              op: "setLayerAnimations" as const,
              layerId: layer.id,
              animations: layer.animations,
              anchor: layer.anchor,
            }]
            : []),
        ], { offCanvas: "clamp" });
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    renderSticker: async () => {
      const call = await openCall("view_sticker");
      try {
        const render = await renderWorkingDocument(working, job.ownerId);
        await finishToolCall(job, call, "complete", render);
        return render;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    applyOperations: async (operations) => {
      const call = await openCall("edit_layers");
      try {
        for (const operation of operations) validateEditOperation(operation);
        const state = await land(operations);
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    finalizeEdit: async () => {
      const call = await openCall("finalize_edit");
      try {
        await finishToolCall(job, call, "complete", { revision: changes, document: working });
        return { revision: changes, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
  };

  let result: { revision: number; finalized: boolean } | undefined;
  if (options.video) {
    // The chat tool already selected the layer and motion; no second model decision is needed.
    await session.createVideoLayer(options.video);
    const finalized = await session.finalizeEdit();
    result = { revision: finalized.revision, finalized: true };
  } else {
    result = await getAiProvider().editSticker({
      presetGuidance: creationPresetGuidance(sticker.creationPresets),
      presetReferences: await creationPresetReferences(sticker.creationPresets),
      document: base,
      instruction,
      history,
      targetLayerId: options.targetLayerId,
      imagePlacement: options.imagePlacement,
      attachmentCount: options.references.length,
      references: options.references,
    }, session);
  }

  // Before anything below reports on the model, so a turn the user stopped is not also blamed on it.
  await assertJobStillRunning(job.id);

  // The model looked at the sticker and changed nothing — because what the user asked for was
  // already true, or because it is not something an edit can do. Answering in words beats failing
  // the turn: nothing was lost, and the user is told why rather than shown a red error.
  if (changes === 0) {
    await finishToolCall(job, toolCallId);
    const message = await getAiProvider().reply(instruction, [history, creationPresetGuidance(sticker.creationPresets)].filter(Boolean).join("\n\n"));
    return turnResult(await insertAssistantMessage(job, message, "text"));
  }
  // The loop can also stop on its step cap, or because finalize_edit itself threw. A candidate the
  // user can look at and reject beats a dead turn, so ship whatever landed.
  if (!result?.finalized) {
    console.warn("Finalizing an unfinished edit loop", { jobId: job.id, stickerId: sticker.id, changes });
  }
  // Every landing already kept the layout on canvas; this catches nothing unless a future operation
  // forgets to, and it is cheap enough to keep as the invariant's last word.
  const document = clampLayoutOnCanvas(working);

  // Whatever artwork the edited sticker ends up carrying. An edit that only rearranged layers drew
  // nothing, so this is usually the base revision's own master, carried over untouched. A clip's
  // poster counts: `create_video` turns an image layer into a video one, and a sticker whose only
  // artwork went that way would otherwise sit in the library as a blank card until it is published.
  const firstImageAssetId = document.layers.flatMap((layer) =>
    layer.type === "image" ? [layer.assetId] : layer.type === "video" ? [layer.posterAssetId] : [])[0];
  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision.id,
    masterAssetId: firstImageAssetId,
    previewAssetId: firstImageAssetId,
  });
  traceEvent("editTurn:candidate", { jobId: job.id, revisionId, changes, generations, layers: document.layers.length });
  await finishToolCall(job, toolCallId);
  const content = await showStickerThroughTool(job, revisionId, document.kind, instruction, history);
  const assistantMessageId = await insertAssistantMessage(job, content, "image_edit", revisionId);
  const turn = await turnResult(assistantMessageId, revisionId);
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot: snapshot + 1, revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assistantMessage: turn.assistantMessage,
  });
  return turn;
}
