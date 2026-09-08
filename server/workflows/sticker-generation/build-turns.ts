// Building a confirmed plan into a finished composition, and the layout pass that settles
// where its parts sit.

import { and, desc, eq, inArray } from "drizzle-orm";
import { planRequiresConcept, PlanV1Schema } from "@/lib/contracts/plan";
import { type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, generationJobs, plans, stickerRevisions, stickers } from "@/lib/db/schema";
import { getAiProvider, TurnAbort, type LayoutDraftingSession, type AiImageReferenceCandidate } from "@/lib/ai/gateway";
import { applyLayoutAdjustment, clampLayoutOnCanvas, layoutDiagnostics } from "@/lib/layout/composition";
import { applyMeasuredPlacements, measuredPlacements } from "@/lib/layout/placement";
import { type SubjectBounds } from "@/lib/images/subject-bounds";
import { traceEvent } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { createCandidateRevision } from "@/lib/services/stickers";
import { downscaleForModelInput, getObjectStore } from "@/lib/storage/r2";
import { documentFromPlan, generateAndStoreAsset, generateAndStoreVideoAsset, generatedLayers, selectImageReferences } from "./asset-generation";
import type { StoredVideoTiming } from "./asset-generation";
import { assertDocumentAssetsOwned, assertJobStillRunning, beginToolCall, finishToolCall, insertAssistantMessage, renderWorkingDocument, showStickerThroughTool, toolCallLabeller, turnResult } from "./turn-context";
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
): Promise<StickerDocument> {
  // One layer has no inter-layer composition to repair. Skipping it also avoids adding a vision
  // round trip to plans whose only reason to exist is structured motion.
  if (document.layers.length < 2) return document;

  let working = document;
  let reviewed: StickerDocument | undefined;
  let revision = 0;
  let viewedRevision = -1;
  let viewedPlanImage = reference === undefined;
  const nextLabel = toolCallLabeller();
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
        const render = await renderWorkingDocument(working, job.ownerId);
        reviewed = working;
        viewedRevision = revision;
        await finishToolCall(job, call, "complete", render);
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
        await assertDocumentAssetsOwned(landed, job.ownerId, job.stickerId).catch(abort);
        working = landed;
        revision += 1;
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
        const diagnostics = layoutDiagnostics(working);
        if (diagnostics.offCanvasLayerIds.length > 0) {
          throw new Error(
            `Keep every complete layer box on canvas. Fix: ${diagnostics.offCanvasLayerIds.join(", ")}`,
          );
        }
        await finishToolCall(job, call, "complete", { revision, document: working });
        return { revision, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
  };

  const result = await getAiProvider().refineStickerLayout(
    { document, instruction, history },
    session,
  );
  await assertJobStillRunning(job.id);
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
  const generated = generatedLayers(plan, job.id);
  const visualReference = planRequiresConcept(plan)
    ? await loadPlanVisualReference(planRow, job.ownerId, sticker.id)
    : undefined;

  const primaryToolCallId = await beginToolCall(job, "build-plan");
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
    stage: "composing",
    progress: 0.05,
    partCount: generated.length,
    layerCount: plan.layers.length,
  });

  // Progress is split by what each part costs in wall clock: the stills share the first stretch
  // and any clip takes the next, so a turnaround that runs for minutes is not shown as stuck at
  // the end of an image bar.
  const videoCount = generated.filter((item) => item.video).length;
  const stillSpan = videoCount > 0 ? 0.5 : 0.7;
  const videoTimings = new Map<string, StoredVideoTiming>();

  // Where each separated part came back in the reference frame. Only meaningful when there is a
  // reference: a part drawn from its prompt alone was drawn wherever the model liked.
  const separatedParts: Array<{ layerId: string; subject: SubjectBounds | undefined }> = [];
  for (const [index, item] of generated.entries()) {
    await assertJobStillRunning(job.id);
    const label = `compose-part:${index} ${item.layer.name}`;
    const partToolCallId = await beginToolCall(job, "build-plan", undefined, label);
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
      const selectedReferences = await selectImageReferences(prompt, history, candidates);
      const { subject } = await generateAndStoreAsset(job, sticker.id, {
        assetId: item.assetId,
        prompt,
        // The approved concept is mandatory because it is the exact design being separated. The
        // orchestrator sees every remaining candidate and decides which originals materially help
        // this particular layer; only its selected full-resolution images reach the image model.
        references: selectedReferences,
        conversationContext: history,
        // This is an edit of the approved pixels, not a fresh generation inspired by them. The GPT
        // Image edit path is instructed to remove every other part while preserving this one; the
        // prompt still names the mode so tests and provider adapters can enforce that distinction.
        mode: visualReference ? "conversation_edit" : "generate",
      });
      if (visualReference) separatedParts.push({ layerId: item.layer.layerId, subject });
    } catch (error) {
      await finishToolCall(job, partToolCallId, "failed", error);
      throw error;
    }
    await finishToolCall(job, partToolCallId);
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_part",
      progress: 0.05 + stillSpan * ((index + 1) / Math.max(generated.length, 1)),
      partIndex: index,
      partName: item.layer.name,
      partCount: generated.length,
    });
  }

  // Clips after every still, not interleaved: a clip is the slowest thing in the build, and a
  // turn that is going to fail on its second image should fail before paying for a video.
  let videosDone = 0;
  for (const item of generated) {
    if (!item.video) continue;
    await assertJobStillRunning(job.id);
    const videoToolCallId = await beginToolCall(job, "build-plan", undefined, `compose-video ${item.layer.name}`);
    try {
      const timing = await generateAndStoreVideoAsset(job, sticker.id, { stillAssetId: item.assetId, video: item.video });
      videoTimings.set(item.layer.layerId, timing);
    } catch (error) {
      await finishToolCall(job, videoToolCallId, "failed", error);
      throw error;
    }
    await finishToolCall(job, videoToolCallId);
    videosDone += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "composing_video",
      progress: 0.05 + stillSpan + 0.2 * (videosDone / videoCount),
      partName: item.layer.name,
      videoIndex: videosDone - 1,
      videoCount,
    });
  }

  let document = documentFromPlan(plan, job.id, videoTimings);
  // The reference is the picture the user approved, so a part measured in it outranks the position
  // the planner guessed before that picture existed. Parts whose measurement is implausible keep
  // the plan's layout, and the review below still looks at the whole.
  const placements = measuredPlacements(separatedParts);
  if (placements.size > 0) {
    traceEvent("composeLayout:measured", { jobId: job.id, layerIds: [...placements.keys()] });
    document = applyMeasuredPlacements(document, placements);
  }
  // Covers the reused layers too: an `existing` source names an asset by id, and this is what stops
  // a plan from pointing at another sticker's artwork, or at one that has since been swept.
  await assertDocumentAssetsOwned(document, job.ownerId, sticker.id);
  document = await refineBuiltLayout(
    job,
    document,
    `${plan.title}. ${plan.summary}`,
    history,
    visualReference,
  );
  const firstImageAssetId = document.layers.find((layer) => layer.type === "image")?.assetId;
  let snapshot = 0;
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document });

  await assertJobStillRunning(job.id);
  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision?.id,
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
}
