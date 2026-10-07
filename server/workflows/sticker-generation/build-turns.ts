import { loadPlanBase } from "@/lib/services/plan-base";
import { loadCreationPresetGuidance, loadCreationPresetReferences } from "@/lib/creation-presets/guidance";
import { BuildReviewCheckpointSchema, loadBuildCheckpoint, saveBuildCheckpoint, completedBuildSteps, buildAssetsReady, type BuildReviewCheckpoint } from "./build-checkpoints";
import { generatePlannedVariants } from "./configurable-artwork";
import { generateSpriteArtwork } from "./sprite-artwork";
import { configurationReviewSelections, configurationEditReviewSelections, type StickerConfiguration } from "@/lib/contracts/configuration";
import { resolveStickerConfiguration } from "@/lib/contracts/sticker";
// Building a confirmed plan into a finished composition, and the layout pass that settles
// where its parts sit.

import { and, desc, eq, inArray } from "drizzle-orm";
import { planRequiresConcept, PlanV1Schema } from "@/lib/contracts/plan";
import { type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, generationJobs, plans, stickerRevisions, stickers } from "@/lib/db/schema";
import { getAiProvider, TurnAbort, type LayoutDraftingSession, type AiImageReferenceCandidate } from "@/lib/ai/gateway";
import { applyLayoutAdjustment, clampLayoutOnCanvas, layoutDiagnostics } from "@/lib/layout/composition";
import { additionsCoveringRetained, applyMeasuredPlacements, measuredPlacements, placementsOffRetained } from "@/lib/layout/placement";
import { type SubjectBounds } from "@/lib/images/subject-bounds";
import { traceEvent } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { createCandidateRevision } from "@/lib/services/stickers";
import { downscaleForModelInput, getObjectStore } from "@/lib/storage/r2";
import { documentFromPlan, generateAndStoreAsset, generateAndStoreVideoAsset, generatedLayers, loadStoredGeneratedImage, selectImageReferences } from "./asset-generation";
import type { StoredVideoTiming } from "./asset-generation";
import { assertDocumentAssetsOwned, assertJobStillRunning, beginToolCall, finishToolCall, insertAssistantMessage, renderWorkingDocument, reportTurnNote, showStickerThroughTool, turnResult } from "./turn-context";
import type { AiTurnResult, StickerToolName } from "./turn-context";

/**
 * Reviews the assembled pixels and lands layout-only corrections before a candidate is created.
 *
 * The generated assets are immutable here. The session accepts a narrow placement/order contract,
 * applies it with the layer's existing animation specs, and rejects any adjusted document whose
 * conservative layer boxes leave the canvas. A render marks a revision as reviewed; if the model
 * runs out of steps after another change, the last actually viewed revision wins rather than an
 * uninspected draft leaking out as the candidate.
 */
async function refineBuiltLayout(
  job: typeof generationJobs.$inferSelect,
  document: StickerDocument,
  instruction: string,
  history: string,
  /** The approved static reference every part was separated from, when the plan had one. */
  reference: { bytes: Uint8Array; mimeType: string } | undefined,
  assetJobId: string,
  checkpoint?: BuildReviewCheckpoint,
  animationSummary?: { bytes: Uint8Array; mimeType: string },
  references: Array<{ bytes: Uint8Array; mimeType: string }> = [],
  retainedLayerIds: Set<string> = new Set(),
  baseConfiguration?: StickerConfiguration,
  /** A rule of the build's own every adjustment must keep; throws to refuse one. */
  assertLayout?: (document: StickerDocument) => void,
): Promise<StickerDocument> {
  // One layer has no inter-layer composition to repair. Skipping it also avoids adding a vision
  // round trip to plans whose only reason to exist is structured motion.
  if (checkpoint?.finalized || (document.layers.length < 2 && !document.configuration)) return document;
  const configurations = document.configuration ? baseConfiguration ? configurationEditReviewSelections(baseConfiguration, document.configuration) : configurationReviewSelections(document.configuration) : [{}];
  let configurationCursor = checkpoint?.configurationCursor ?? 0;
  const db = await getDatabase();
  const publishReviewProgress = () => appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "reviewing",
    message: "Reviewing sticker configurations…",
    progressLabel: "Review checks",
    completedUnits: Math.min(configurationCursor, configurations.length),
    totalUnits: configurations.length,
  });
  await publishReviewProgress();

  let working = document;
  let reviewed = checkpoint?.reviewed;
  let revision = checkpoint?.revision ?? 0;
  let viewedRevision = checkpoint?.viewedRevision ?? -1;
  let viewedPlanImage = checkpoint?.viewedPlanImage ?? reference === undefined;
  const toolCalls = { ...checkpoint?.toolCalls };
  const saveReview = (finalized = false) => saveBuildCheckpoint(job, assetJobId, "review", {
    document: working, reviewed, configurationCursor, revision, viewedRevision, viewedPlanImage, finalized, toolCalls,
  });
  await saveReview();
  const nextLabel = (name: StickerToolName) => {
    const count = (toolCalls[name] ?? 0) + 1;
    toolCalls[name] = count;
    return count === 1 ? name : `${name} #${count}`;
  };
  const abort = (error: unknown): never => { throw new TurnAbort(error); };
  const openCall = async (toolName: StickerToolName): Promise<string> => {
    try {
      return await beginToolCall(job, toolName, undefined, nextLabel(toolName));
    } catch (error) {
      return abort(error);
    }
  };

  const session: LayoutDraftingSession = {
    ...(reference
      ? {
        viewPlanImage: async () => {
          const call = await openCall("view_plan_image");
          try {
            await assertJobStillRunning(job.id).catch(abort);
            const viewable = await downscaleForModelInput(reference.bytes);
            viewedPlanImage = true;
            await saveReview();
            await finishToolCall(job, call, "complete", viewable);
            return viewable;
          } catch (error) {
            await finishToolCall(job, call, "failed", error);
            return abort(error);
          }
        },
      }
      : {}),
    renderSticker: async () => {
      const call = await openCall("view_sticker");
      try {
        const values = configurations[configurationCursor % configurations.length];
        const render = await renderWorkingDocument(resolveStickerConfiguration(working, values), job.ownerId);
        configurationCursor += 1;
        reviewed = working;
        viewedRevision = revision;
        await saveReview();
        await finishToolCall(job, call, "complete", render);
        await publishReviewProgress();
        return render;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        return abort(error);
      }
    },
    applyLayout: async (adjustment) => {
      const call = await openCall("adjust_layout");
      try {
        if (viewedRevision < 0) {
          throw new Error("Call view_sticker before making the first layout adjustment");
        }
        if (!viewedPlanImage) {
          throw new Error("Call view_plan_image before comparing and adjusting the generated sticker");
        }
        await assertJobStillRunning(job.id).catch(abort);
        const landed = applyLayoutAdjustment(working, adjustment);
        for (const id of retainedLayerIds) {
          if (JSON.stringify(landed.layers.find((layer) => layer.id === id)) !== JSON.stringify(working.layers.find((layer) => layer.id === id))) {
            throw new Error(`Keep existing layer ${id} unchanged; adjust the additions instead`);
          }
        }
        const order = (value: StickerDocument) => value.layers.filter((layer) => retainedLayerIds.has(layer.id)).map((layer) => layer.id).join("|");
        if (order(landed) !== order(working)) throw new Error("Preserve the existing layer order");
        assertLayout?.(landed);
        await assertDocumentAssetsOwned(landed, job.ownerId, job.stickerId).catch(abort);
        working = landed;
        revision += 1;
        configurationCursor = 0;
        await saveReview();
        await publishReviewProgress();
        await finishToolCall(job, call, "complete", { revision, document: working });
        return { revision, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    finalizeLayout: async () => {
      const call = await openCall("finalize_layout");
      try {
        if (viewedRevision !== revision) {
          throw new Error("Call view_sticker on the current layout before finalizing it");
        }
        if (!viewedPlanImage) {
          throw new Error("Call view_plan_image before finalizing the generated sticker");
        }
        if (configurationCursor < configurations.length) throw new Error(`Review all ${configurations.length} configurations with view_sticker before finalizing; ${configurationCursor} viewed`);
        // Retained layers are locked by applyLayout, so demanding they come back on canvas would
        // leave the reviewer finalizing and adjusting in a loop it can never win.
        const offCanvas = layoutDiagnostics(working).offCanvasLayerIds.filter((id) => !retainedLayerIds.has(id));
        if (offCanvas.length > 0) {
          throw new Error(`Keep every complete layer box on canvas. Fix: ${offCanvas.join(", ")}`);
        }
        await saveReview(true);
        await finishToolCall(job, call, "complete", { revision, document: working });
        return { revision, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
  };

  const result = await getAiProvider().refineStickerLayout(
    { presetGuidance: await loadCreationPresetGuidance(job.stickerId), presetReferences: await loadCreationPresetReferences(job.stickerId), references, document, animationSummary, instruction: instruction + (checkpoint ? ` Resuming review: ${configurationCursor} of ${configurations.length} configurations already checked on this exact layout. Continue with the next unchecked configuration; do not restart completed checks. If all checks are done, finalize. The saved layout includes previous adjustments.` : "") + (document.configuration ? ` Review all ${configurations.length} mood/pose configurations. Each successive view_sticker shows the next configuration in this order: ${JSON.stringify(configurations)}. Check expression identity, sprite alignment, pose continuity and clipping before finalizing. After a layout change, review all configurations again.` : ""), history },
    session,
  );
  await assertJobStillRunning(job.id);
  if (document.configuration && (!result?.finalized || configurationCursor < configurations.length)) throw new Error("Expression review did not finish. Retry to reuse the generated artwork.");
  if (!result?.finalized) {
    console.warn("Using the last viewed layout from an unfinished review loop", {
      jobId: job.id,
      stickerId: job.stickerId,
      revision,
      viewedRevision,
    });
  }
  // finalize_layout refuses an off-canvas layout, so a finalized one is clean; the fallbacks are
  // whatever the loop last looked at, which nothing has checked.
  return result?.finalized ? working : clampLayoutOnCanvas(reviewed ?? document);
}

/** Loads the exact static reference attached to the confirmed animated plan. */
export async function loadPlanVisualReference(
  planRow: typeof plans.$inferSelect,
  ownerId: string,
  stickerId: string,
): Promise<{ bytes: Uint8Array; mimeType: string }> {
  if (!planRow.conceptAssetId) {
    throw new Error("Confirmed animated plan is missing its approved static reference");
  }
  const asset = await (await getDatabase()).select().from(assets).where(and(
    eq(assets.id, planRow.conceptAssetId),
    eq(assets.ownerId, ownerId),
    eq(assets.stickerId, stickerId),
    eq(assets.state, "ready"),
  )).then(firstRow);
  if (!asset) throw new Error("Approved static plan reference is unavailable");
  const object = await getObjectStore().get(asset.r2Key);
  return { bytes: object.bytes, mimeType: asset.mimeType };
}

/** Loads the confirmed revision's storyboard; older plans may have no overview. */
export async function loadPlanAnimationSummary(
  planRow: typeof plans.$inferSelect,
  ownerId: string,
  stickerId: string,
): Promise<{ bytes: Uint8Array; mimeType: string } | undefined> {
  if (!planRow.animationPreviewAssetId) return undefined;
  const asset = await (await getDatabase()).select().from(assets).where(and(
    eq(assets.id, planRow.animationPreviewAssetId),
    eq(assets.ownerId, ownerId), eq(assets.stickerId, stickerId), eq(assets.state, "ready"),
  )).then(firstRow);
  if (!asset) throw new Error("Approved animation summary is unavailable");
  const object = await getObjectStore().get(asset.r2Key);
  return { bytes: object.bytes, mimeType: asset.mimeType };
}

/**
 * Builds a confirmed plan: one image per generate layer, then the document the plan describes.
 *
 * Motion is no longer a second AI pass. The plan already carries structured animation specs that
 * the user approved, so the document is assembled deterministically — which also means a plan whose
 * motion cannot compile fails here *before* any image is paid for, rather than after.
 *
 * `assertValidAnimationBase` is deliberately not called. That guard stops a client branching
 * animation off a revision it does not own or that was never accepted; this document was built in
 * this step from assets created in this step, so there is no such question. The invariants it
 * stands in for still hold: `confirmPlan` rejects a plan whose kind does not match the project, a
 * static document cannot hold a non-zero keyframe by schema, and `assertDocumentAssetsOwned` runs
 * over the finished document.
 */
/** A plan's layer name, bounded to what fits on one line of the chat's working card. */
function partName(name: string): string {
  const trimmed = name.trim();
  return trimmed.length <= 24 ? trimmed : `${trimmed.slice(0, 23)}…`;
}

export async function executePlanBuildTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  sourceMessage: typeof chatMessages.$inferSelect,
  history: string,
  activeRevision: typeof stickerRevisions.$inferSelect | undefined,
  /**
   * The project's own reference photos, for the plans that have no approved concept to copy from.
   *
   * `planRequiresConcept` is false for every static plan, so a static sticker of a real person used
   * to have its layers drawn from the layer prompt and nothing else — the same likeness hole the
   * concept render had, one step further down the pipeline.
   */
  references: Array<{ bytes: Uint8Array; mimeType: string }>,
): Promise<AiTurnResult> {
  const db = await getDatabase();
  let planRow = await db.select().from(plans).where(and(
    eq(plans.jobId, job.id),
    eq(plans.ownerId, job.ownerId),
    eq(plans.stickerId, sticker.id),
  )).then(firstRow);
  // Retrying a failed chat turn creates a new job but deliberately reuses the source message. The
  // confirmed plan remains linked to the original confirmation job, so resolve that job family
  // before declaring the plan missing. This also repairs retries created before this fallback
  // existed; they do not need their persisted plan row rewritten to become runnable.
  if (!planRow && job.sourceMessageId) {
    const composeJobs = await db.select({ id: generationJobs.id }).from(generationJobs).where(and(
      eq(generationJobs.ownerId, job.ownerId),
      eq(generationJobs.stickerId, sticker.id),
      eq(generationJobs.sourceMessageId, job.sourceMessageId),
      eq(generationJobs.kind, "compose"),
    ));
    if (composeJobs.length > 0) {
      planRow = await db.select().from(plans).where(and(
        eq(plans.ownerId, job.ownerId),
        eq(plans.stickerId, sticker.id),
        inArray(plans.jobId, composeJobs.map((candidate) => candidate.id)),
      )).orderBy(desc(plans.decidedAt)).then(firstRow);
    }
  }
  if (!planRow) throw new Error("Plan not found for this job");
  const plan = PlanV1Schema.parse(planRow.planJson);
  const pinnedBase = await loadPlanBase(db, job.ownerId, sticker.id, plan);
  const retainedLayerIds = new Set(pinnedBase?.document.layers.filter((layer) => !plan.layers.some((addition) => addition.layerId === layer.id)).map((layer) => layer.id) ?? []);
  // Only the pet's own growth: an owner extending their sticker may well want a hat on its head.
  const keepAdditionsBeside = job.origin === "pet" && retainedLayerIds.size > 0;
  const additionIds = (document: StickerDocument) => document.layers.map((layer) => layer.id).filter((id) => !retainedLayerIds.has(id));
  // A user retry has a fresh job, but the confirmed plan and its generation slots are immutable.
  // Keep the original namespace so both stills and clips survive any number of failed attempts.
  const assetJobId = planRow.jobId ?? job.id;
  const generated = generatedLayers(plan, assetJobId);
  const visualReference = planRequiresConcept(plan)
    ? await loadPlanVisualReference(planRow, job.ownerId, sticker.id)
    : undefined;

  const animationSummary = await loadPlanAnimationSummary(planRow, job.ownerId, sticker.id);

  const primaryToolCallId = await beginToolCall(job, "build-plan");
  const finishBuild = async (document: StickerDocument, checkpoint?: BuildReviewCheckpoint): Promise<AiTurnResult> => {
    document = await refineBuiltLayout(
      job,
      document,
      `${plan.title}. ${plan.summary}. Preserve these existing layers without changing their layout or artwork: ${[...retainedLayerIds].join(", ")}`
        + (keepAdditionsBeside
          ? ". The additions are accessories that sit beside the character, never over its face or body: where the reference shows one covering the character, keep it beside the character instead."
          : ""),
      history,
      visualReference,
      assetJobId,
      checkpoint,
      animationSummary,
      references,
      retainedLayerIds,
      pinnedBase?.document.configuration,
      keepAdditionsBeside
        ? (landed) => {
          const covering = additionsCoveringRetained(landed, additionIds(landed), retainedLayerIds);
          if (covering.length > 0) throw new Error(`Keep ${covering.join(", ")} beside the character, off its face and body`);
        }
        : undefined,
    );
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "finalizing",
      message: "Finishing your sticker…",
      clearProgress: true,
    });
    // With a cast, the biggest character is the one the thumbnail should be of; "whichever is listed
    // first" is a visible wrong answer once a sticker holds more than one.
    const largestSprite = document.layers.filter((layer) => layer.type === "sprite")
      .sort((a, b) => b.anchor.scale.x * b.anchor.scale.y - a.anchor.scale.x * a.anchor.scale.y)[0];
    const firstImageAssetId = document.layers.find((layer) => layer.type === "image")?.assetId
      ?? largestSprite?.posterAssetId;
    let snapshot = 0;
    await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document });

    await assertJobStillRunning(job.id);
    const revisionId = await createCandidateRevision(db, {
      ownerId: job.ownerId,
      stickerId: sticker.id,
      sourceMessageId: sourceMessage.id,
      document,
      id: job.id,
      parentRevisionId: pinnedBase?.id ?? activeRevision?.id,
      // No single layer is "the" master; the first image one keeps the library thumbnail from being
      // blank until published exports supply a real preview. Read off the document rather than off
      // `generated` so a plan that only rearranges reused artwork still has one. A plan made entirely
      // of text, shape, or particle layers has no image asset at all, which is why these are optional.
      masterAssetId: firstImageAssetId,
      previewAssetId: firstImageAssetId,
    });
    await finishToolCall(job, primaryToolCallId);
    const content = await showStickerThroughTool(job, revisionId, document.kind, plan.title, history);
    const assistantMessageId = await insertAssistantMessage(job, content, "image", revisionId);
    const result = await turnResult(assistantMessageId, revisionId);
    snapshot += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, revisionId, document });
    await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
      revisionId,
      assistantMessageId,
      assetIds: generated.map((item) => item.assetId),
      assistantMessage: result.assistantMessage,
    });
    return result;
  };
  const checkpoint = await loadBuildCheckpoint(job, assetJobId, "review", BuildReviewCheckpointSchema);
  if (checkpoint) {
    await assertDocumentAssetsOwned(checkpoint.document, job.ownerId, sticker.id);
    return finishBuild(checkpoint.document, checkpoint);
  }
  const videoCount = generated.filter((item) => item.video).length;
  const stillSpan = videoCount > 0 ? 0.5 : 0.7;
  const storedParts = await Promise.all(generated.map((item) => loadStoredGeneratedImage(job, sticker.id, item.assetId)));
  const pendingParts = generated.flatMap((item, index) => storedParts[index] ? [] : [{ item, index }]);
  let partsDone = generated.length - pendingParts.length;
  if (pendingParts.length) await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "composing",
    progress: 0.05 + stillSpan * (partsDone / Math.max(generated.length, 1)),
    partCount: generated.length,
    progressLabel: "Artwork parts",
    completedUnits: partsDone,
    totalUnits: generated.length,
    layerCount: plan.layers.length,
  });

  // Progress is split by what each part costs in wall clock: the stills share the first stretch
  // and any clip takes the next, so a turnaround that runs for minutes is not shown as stuck at
  // the end of an image bar.
  const videoTimings = new Map<string, StoredVideoTiming>();

  // Where each separated part came back in the reference frame. Only meaningful when there is a
  // reference: a part drawn from its prompt alone was drawn wherever the model liked.
  const separatedParts: Array<{ layerId: string; subject: SubjectBounds | undefined }> = [];
  if (visualReference) storedParts.forEach((stored, index) => {
    if (stored) separatedParts[index] = { layerId: generated[index].layer.layerId, subject: stored.subject };
  });
  const partConcurrency = 3;
  let progressWrites = Promise.resolve();
  for (let offset = 0; offset < pendingParts.length; offset += partConcurrency) {
    // Allocate transcript sequences serially before starting this batch's independent AI calls.
    const batch = [];
    for (const { item, index } of pendingParts.slice(offset, offset + partConcurrency)) {
      await assertJobStillRunning(job.id);
      const label = `compose-part:${index} ${item.layer.name}`;
      const partToolCallId = await beginToolCall(job, "build-plan", undefined, label);
      await reportTurnNote(job, `Drawing ${partName(item.layer.name)}`);
      batch.push({ index, item, partToolCallId });
    }
    const results = await Promise.allSettled(batch.map(async ({ index, item, partToolCallId }) => {
      try {
        const prompt = visualReference
          ? [
              `Separate only the "${item.layer.name}" part from the approved static sticker reference.`,
              "Copy it from the approved reference instead of redesigning or simplifying it.",
              "Preserve its exact silhouette, design, colours, outlines, bevels, highlights,",
              "shadows, texture, and proportions.",
              "Return that one part isolated on a transparent background; omit every other part.",
              // Where the part sits in the reference is where it belongs on the canvas, and the
              // build reads that position off the pixels that come back. Moved or enlarged, the
              // measurement is wrong and the layer lands somewhere the user did not approve.
              "Keep the part exactly where it sits in the reference, at exactly the same size and",
              "position within the 1024x1024 frame: do not move it, centre it, enlarge it, or crop",
              "the frame. Make every other pixel fully transparent.",
              `Part description: ${item.prompt}`,
            ].join(" ")
          : item.prompt;
        const candidates: AiImageReferenceCandidate[] = [
          ...(visualReference
            ? [{ label: "approved plan image", image: visualReference, required: true }]
            : []),
          ...references.map((image, referenceIndex) => ({
            label: `original or carried reference ${referenceIndex + 1}`,
            image,
          })),
        ].slice(0, 8);
        const stored = await loadStoredGeneratedImage(job, sticker.id, item.assetId);
        const { subject } = stored ?? await generateAndStoreAsset(job, sticker.id, {
          assetId: item.assetId,
          prompt,
          // The approved concept is mandatory because it is the exact design being separated. The
          // orchestrator sees every remaining candidate and decides which originals materially help
          // this particular layer; only its selected full-resolution images reach the image model.
          references: await selectImageReferences(prompt, history, candidates),
          conversationContext: history,
          // This is an edit of the approved pixels, not a fresh generation inspired by them. The GPT
          // Image edit path is instructed to remove every other part while preserving this one; the
          // prompt still names the mode so tests and provider adapters can enforce that distinction.
          mode: visualReference ? "conversation_edit" : "generate",
        });
        if (visualReference) separatedParts[index] = { layerId: item.layer.layerId, subject };
      } catch (error) {
        await finishToolCall(job, partToolCallId, "failed", error);
        throw error;
      }
      await finishToolCall(job, partToolCallId, "complete", { previewAssetId: item.assetId });
      // Completions can arrive out of order. Serialize their progress writes so the displayed
      // fraction follows completed work and never moves backwards.
      progressWrites = progressWrites.then(async () => {
        partsDone += 1;
        await reportTurnNote(job, `Finished ${partName(item.layer.name)} (${partsDone} of ${generated.length})`);
        await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
          stage: "composing_part",
          progress: 0.05 + stillSpan * (partsDone / Math.max(generated.length, 1)),
          partIndex: index,
          partName: item.layer.name,
          partCount: generated.length,
          progressLabel: "Artwork parts",
          completedUnits: partsDone,
          totalUnits: generated.length,
        });
      });
      await progressWrites;
    }));
    // Let in-flight parts finish storing before failing the job, so a retry can reuse them.
    // A failed batch never starts more parts or purchases any videos.
    const failure = results.find((result) => result.status === "rejected");
    if (failure?.status === "rejected") throw failure.reason;
  }

  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "assembling",
    message: "Preparing animation and assembly…",
    clearProgress: true,
  });

  // Clips after every still, not interleaved: a clip is the slowest thing in the build, and a
  // turn that is going to fail on its second image should fail before paying for a video.
  const completedSteps = await completedBuildSteps(job);
  const reusedVideos = new Set<string>();
  for (const item of generated) if (item.video && completedSteps.has(`compose-video ${item.layer.name}`)
    && await buildAssetsReady(job, [item.video.assetId])) reusedVideos.add(item.video.assetId);
  let videosDone = reusedVideos.size;
  if (videosDone < videoCount) {
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_video", message: "Composing video clips…",
      progressLabel: "Video clips", completedUnits: videosDone, totalUnits: videoCount,
    });
  }
  for (const item of generated) {
    if (!item.video) continue;
    await assertJobStillRunning(job.id);
    const videoLabel = `compose-video ${item.layer.name}`;
    const reusedVideo = reusedVideos.has(item.video.assetId);
    const videoToolCallId = reusedVideo ? undefined : await beginToolCall(job, "build-plan", undefined, videoLabel);
    try {
      const timing = await generateAndStoreVideoAsset(job, sticker.id, { stillAssetId: item.assetId, video: item.video });
      videoTimings.set(item.layer.layerId, timing);
    } catch (error) {
      await finishToolCall(job, videoToolCallId, "failed", error);
      throw error;
    }
    await finishToolCall(job, videoToolCallId, "complete", { previewAssetId: item.assetId });
    if (reusedVideo) continue;
    videosDone += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_video",
      progress: 0.05 + stillSpan + 0.2 * (videosDone / videoCount),
      partName: item.layer.name,
      videoIndex: videosDone - 1,
      videoCount,
      progressLabel: "Video clips",
      completedUnits: videosDone,
      totalUnits: videoCount,
    });
  }

  // Sprites after the stills and clips, for the same reason clips follow stills: each sheet is drawn
  // from the layer's separated still, and a sprite is the most generations any one layer can cost.
  // A sticker that was not asked to move keeps its sprite frames on one ground line too, not just
  // its layer motion: otherwise the drawn frames bob the character up and down in place.
  const spriteBuilds = await generateSpriteArtwork(job, sticker.id, plan, assetJobId, visualReference, animationSummary, { stayPut: !sticker.motion });
  await generatePlannedVariants(job, sticker.id, plan, assetJobId, visualReference, pinnedBase?.document);
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "assembling", message: "Assembling your sticker…", clearProgress: true,
  });
  let document = documentFromPlan(plan, assetJobId, videoTimings, spriteBuilds, pinnedBase?.document);
  // The reference is the picture the user approved, so a part measured in it outranks the position
  // the planner guessed before that picture existed. Parts whose measurement is implausible keep
  // the plan's layout, and the review below still looks at the whole.
  const placements = measuredPlacements(separatedParts);
  if (placements.size > 0) {
    traceEvent("composeLayout:measured", { jobId: job.id, layerIds: [...placements.keys()] });
    document = applyMeasuredPlacements(document, placements);
  }
  // The pet's growth is an accessory beside the character, however the sketch drew it: an addition
  // left over the character's face or body is moved off it, since the character itself is locked.
  if (keepAdditionsBeside) {
    const offCharacter = placementsOffRetained(document, additionIds(document), retainedLayerIds);
    if (offCharacter.size > 0) {
      traceEvent("composeLayout:offCharacter", { jobId: job.id, layerIds: [...offCharacter.keys()] });
      document = applyMeasuredPlacements(document, offCharacter);
    }
  }
  // Covers the reused layers too: an `existing` source names an asset by id, and this is what stops
  // a plan from pointing at another sticker's artwork, or at one that has since been swept.
  await assertDocumentAssetsOwned(document, job.ownerId, sticker.id);
  return finishBuild(document);
}