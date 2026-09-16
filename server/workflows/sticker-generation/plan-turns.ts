import { creationPresetReferences } from "@/lib/creation-presets/references";
// The two turns that work from a plan: drafting one for the user to confirm, and animating a
// document the user has already accepted.

import { creationPresetGuidance } from "@/lib/creation-presets/selection";
import { renderPlanAnimationPreview } from "./plan-animation-preview";
import { and, eq } from "drizzle-orm";
import { FatalError } from "workflow";
import { assertAnimatedPlanUsesReferenceBackedArtwork, assertControllablePlan, assertPlanPosePreset, assertPlanAllowedForJob, assertPlanReuseIsResolvable, assertSpriteFaces, planRequiresConcept, type PlanV1 } from "@/lib/contracts/plan";
import { applyStickerOperationsV1, type StickerDocument, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { firstRow, getDatabase, type Database } from "@/lib/db/client";
import { chatMessages, generationJobs, plans, stickerRevisions, stickers } from "@/lib/db/schema";
import { animationOperationLayerId, getAiProvider, TurnAbort, validatePlannedAnimationOperation, type AnimationDraftingSession, type PlanDraftingSession, type AiPlanVisual, type AiSequenceAsset } from "@/lib/ai/gateway";
import { derivedAssetId, ensureAtlasPoster } from "@/lib/services/assets";
import { appendGenerationEvent } from "@/lib/services/events";
import { attachPlanConcept, createPlan, finalizePlan, recentlyRejectedPlans, updatePlan } from "@/lib/services/plans";
import { createCandidateRevision } from "@/lib/services/stickers";
import { generateAndStoreAsset, selectImageReferences } from "./asset-generation";
import { assertDocumentAssetsOwned, assertJobStillRunning, assertTargetedAnimationOperation, beginToolCall, finishToolCall, insertAssistantMessage, renderWorkingDocument, showStickerThroughTool, toolCallLabeller, turnResult } from "./turn-context";
import type { AiTurnResult, StickerToolName } from "./turn-context";

/**
 * Posts, or updates in place, the single plan card a drafting turn produces.
 *
 * One card per turn rather than one per `show_plan` call: `insertAssistantMessage` treats "this job
 * already has an assistant message" as the replay signal, and three stacked cards for one turn
 * would be noise anyway. Re-showing a revised draft rewrites the same card.
 */
async function upsertPlanCard(
  job: typeof generationJobs.$inferSelect,
  planId: string,
  revision: number,
  summary: string,
): Promise<string> {
  const db = await getDatabase();
  const existing = await db.select({ id: chatMessages.id }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).then(firstRow);
  if (existing) {
    await db.update(chatMessages).set({ content: summary, kind: "plan", planId, planRevision: revision })
      .where(eq(chatMessages.id, existing.id));
    return existing.id;
  }
  const id = await insertAssistantMessage(job, summary, "plan");
  await db.update(chatMessages).set({ planId, planRevision: revision }).where(eq(chatMessages.id, id));
  return id;
}

function planReferencePrompt(plan: PlanV1): string | undefined {
  if (!planRequiresConcept(plan)) return undefined;
  if (plan.conceptPrompt) return plan.conceptPrompt;
  if (plan.kind !== "animated") return undefined;

  const parts = plan.layers.map((layer) => {
    const source = layer.source;
    const description = source.kind === "generate"
      ? source.prompt
      : source.kind === "existing"
        ? `the existing approved artwork named ${layer.name}`
        : source.kind === "text"
          ? `the text "${source.text}" in ${source.color}`
          : source.kind === "shape"
            ? `a ${source.fill} ${source.shape}`
            : source.kind === "particle"
              ? `${source.color} ${source.preset}`
              : `the person or subject the user captured, named ${layer.name}`;
    return `${layer.name}: ${description}, centred near (${layer.x}, ${layer.y})`;
  });
  return [
    `${plan.title}. ${plan.summary}`,
    "Draw the complete finished sticker in its resting pose as one polished, coherent still image.",
    `Include these parts in the same composition: ${parts.join("; ")}.`,
  ].join(" ");
}

/**
 * Gives a capture-led plan the one thing it can show: the first frame of the user's own footage.
 *
 * These plans render no concept — `planRequiresConcept` exempts them because the captured frames
 * *are* the reference — which left the card with nothing above its layout boxes. The footage is the
 * subject of the whole design, so showing tile 0 of the atlas is both the most useful preview
 * available and the only one that costs no generation.
 *
 * Best-effort throughout: a plan card without a thumbnail is worse than one with, but neither is
 * worth failing a planning turn over, and confirmation does not depend on this asset existing.
 */
async function attachCapturePreview(
  db: Database,
  stickerId: string,
  planId: string,
  plan: PlanV1,
): Promise<void> {
  const capture = plan.layers.map((layer) => layer.source).find((source) => source.kind === "sequence");
  if (!capture) return;
  const row = await db.select({ conceptAssetId: plans.conceptAssetId }).from(plans)
    .where(eq(plans.id, planId)).then(firstRow);
  const poster = derivedAssetId(capture.assetId, "poster");
  if (row?.conceptAssetId === poster) return;
  const sticker = await db.select({ ownerId: stickers.ownerId }).from(stickers)
    .where(eq(stickers.id, stickerId)).then(firstRow);
  if (!sticker) return;
  const attached = await ensureAtlasPoster(db, sticker.ownerId, stickerId, capture);
  if (attached) await attachPlanConcept(db, planId, attached);
}

/**
 * Generates the static visual source of truth for a plan revision.
 *
 * Animated plans cannot proceed without it. The asset id is derived from the prompt that draws the
 * picture, which is what makes the draft's artwork cacheable without ever going stale: a redraft
 * that words the reference the same way — a replayed step, or an `update_plan` that only moves a
 * layout box — finds the image already stored and pays nothing, while any change to the wording is
 * a different id and so a different picture. Keying it on the revision instead bought that
 * staleness guarantee by re-drawing on every revision, including the ones that changed nothing the
 * image could show.
 */
async function renderPlanConcept(
  job: typeof generationJobs.$inferSelect,
  stickerId: string,
  planId: string,
  revision: number,
  plan: PlanV1,
  references: Array<{ bytes: Uint8Array; mimeType: string }>,
  history: string,
): Promise<void> {
  const db = await getDatabase();
  const prompt = planReferencePrompt(plan);
  if (!prompt) return attachCapturePreview(db, stickerId, planId, plan);
  const row = await db.select({ conceptAssetId: plans.conceptAssetId }).from(plans)
    .where(eq(plans.id, planId)).then(firstRow);
  const assetId = derivedAssetId(planId, `concept:${prompt}`);
  if (row?.conceptAssetId === assetId) {
    await renderPlanAnimationPreview(job, stickerId, planId, revision, plan);
    return;
  }

  const generate = async () => {
    const selectedReferences = await selectImageReferences(
      prompt,
      history,
      references.map((image, index) => ({
        label: `original or carried reference ${index + 1}`,
        image,
      })),
    );
    await generateAndStoreAsset(job, stickerId, {
      assetId,
      prompt,
      references: selectedReferences,
      mode: "generate",
      concept: true,
    });
    await attachPlanConcept(db, planId, assetId);
  };
  if (plan.kind === "animated") {
    await generate();
    await renderPlanAnimationPreview(job, stickerId, planId, revision, plan);
  } else {
    try {
      await generate();
    } catch {
      // Static plans do not depend on a reference image, so an optional preview stays best-effort.
    }
  }
}

/**
 * Runs the agent's plan-drafting loop and ends the turn with a card for the user to decide on.
 *
 * The model creates and revises a draft, then an animated plan renders one static reference for the
 * user to approve. Only confirmation starts the `compose` job that separates generated artwork into
 * transparent parts and assembles the animation.
 */
export async function executePlanTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  threadId: string,
  instruction: string,
  /**
   * The whole conversation, not the digest the other turns get: this is the only loop whose job is
   * to re-read the brief rather than to change a document, so it is built with `keepChatVerbatim`.
   */
  history: string,
  activeDocument: StickerDocument | undefined,
  /** Everything a concept render draws from: the user's attachments, padded with existing artwork. */
  references: Array<{ bytes: Uint8Array; mimeType: string }>,
  /** The subset the planner itself is shown — only what the user attached this turn. */
  attachedImages: Array<{ bytes: Uint8Array; mimeType: string }>,
  /** What the project already looks like, so a turn with no attachment is not planned blind. */
  priorArt: AiPlanVisual[],
  sequenceAssets: AiSequenceAsset[],
  toolCallId: string | undefined,
): Promise<AiTurnResult> {
  const db = await getDatabase();
  const rejected = await recentlyRejectedPlans(db, job.ownerId, sticker.id);
  // The message the plan is anchored to must exist before the row that references it, and the
  // drafting turn has not written its assistant message yet. The tool-call row for `plan-sticker`
  // is a real message on this thread, so it anchors the plan until the card replaces it.
  const anchorMessageId = toolCallId ?? job.sourceMessageId!;

  let latest: { planId: string; revision: number; plan: PlanV1 } | undefined;
  // One transcript row per call, retries included: `beginToolCall` de-duplicates on the label, so a
  // second `finalize_plan` after a failed one would reuse the row it already marked failed and
  // `finishToolCall` — which only moves a row that is still streaming — could never clear it. The
  // user was left reading a permanently broken step for a call that went on to succeed.
  const nextLabel = toolCallLabeller();

  const session: PlanDraftingSession = {
    createPlan: async (plan) => {
      const call = await beginToolCall(job, "create_plan", undefined, nextLabel("create_plan"));
      try {
        assertPlanAllowedForJob(plan, job);
        if (sticker.controllable) assertControllablePlan(plan);
        assertSpriteFaces(plan);
        if (sticker.posePreset) {
          assertPlanPosePreset(plan, sticker.posePreset);
          plan = { ...plan, posePreset: sticker.posePreset };
        }
        assertAnimatedPlanUsesReferenceBackedArtwork(plan);
        assertPlanReuseIsResolvable(plan, activeDocument, sequenceAssets.map((asset) => asset.assetId));
        const created = await createPlan(db, {
          ownerId: job.ownerId,
          stickerId: sticker.id,
          threadId,
          messageId: anchorMessageId,
          plan,
          // Deterministic so a workflow replay reuses the same plan row instead of stacking a
          // second draft that supersedes the first.
          planId: derivedAssetId(job.id, "plan"),
        });
        latest = { planId: created.planId, revision: created.revision, plan };
        await finishToolCall(job, call, "complete", { planId: created.planId, revision: created.revision });
        return { planId: created.planId, revision: created.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    updatePlan: async (planId, plan) => {
      const call = await beginToolCall(job, "update_plan", undefined, nextLabel("update_plan"));
      try {
        assertPlanAllowedForJob(plan, job);
        if (sticker.controllable) assertControllablePlan(plan);
        assertSpriteFaces(plan);
        if (sticker.posePreset) {
          assertPlanPosePreset(plan, sticker.posePreset);
          plan = { ...plan, posePreset: sticker.posePreset };
        }
        assertAnimatedPlanUsesReferenceBackedArtwork(plan);
        assertPlanReuseIsResolvable(plan, activeDocument, sequenceAssets.map((asset) => asset.assetId));
        const updated = await updatePlan(db, { ownerId: job.ownerId, stickerId: sticker.id, planId, plan });
        latest = { planId: updated.planId, revision: updated.revision, plan };
        await finishToolCall(job, call, "complete", updated);
        return updated;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    showPlan: async (planId) => {
      const call = await beginToolCall(job, "show_plan", undefined, nextLabel("show_plan"));
      try {
        if (!latest) throw new Error("There is no plan to show yet");
        await renderPlanConcept(job, sticker.id, planId, latest.revision, latest.plan, references, history);
        await upsertPlanCard(job, planId, latest.revision, latest.plan.summary);
        await finishToolCall(job, call, "complete", { planId, revision: latest.revision });
        return { planId, revision: latest.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    finalizePlan: async (planId) => {
      const call = await beginToolCall(job, "finalize_plan", undefined, nextLabel("finalize_plan"));
      try {
        if (!latest) throw new Error("There is no plan to finalize yet");
        await renderPlanConcept(job, sticker.id, planId, latest.revision, latest.plan, references, history);
        const finalized = await finalizePlan(db, { ownerId: job.ownerId, stickerId: sticker.id, planId });
        latest = { planId: finalized.planId, revision: finalized.revision, plan: finalized.plan };
        await finishToolCall(job, call, "complete", { planId: finalized.planId, revision: finalized.revision });
        return { planId: finalized.planId, revision: finalized.revision };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
  };

  const result = await getAiProvider().planSticker({
    presetGuidance: creationPresetGuidance(sticker.creationPresets),
      presetReferences: await creationPresetReferences(sticker.creationPresets),
    instruction,
    history,
    stickerKind: sticker.kind,
    controllable: sticker.controllable,
    posePreset: sticker.posePreset ?? undefined,
    document: activeDocument,
    rejectedReasons: rejected.map((row) => row.decisionReason).filter((reason): reason is string => Boolean(reason)),
    sequenceAssets,
    references: references.length ? references : attachedImages,
    priorArt,
  }, session);

  if (!latest) throw new Error("The planner finished without drafting a plan");

  // The loop can also stop on its step cap. A draft the user can look at and reject beats a dead
  // turn, so finalize whatever the model got to rather than failing.
  if (!result?.finalized) {
    await renderPlanConcept(job, sticker.id, latest.planId, latest.revision, latest.plan, references, history);
    const finalized = await finalizePlan(db, {
      ownerId: job.ownerId,
      stickerId: sticker.id,
      planId: latest.planId,
    });
    latest = { planId: finalized.planId, revision: finalized.revision, plan: finalized.plan };
  }

  await finishToolCall(job, toolCallId);
  const assistantMessageId = await upsertPlanCard(job, latest.planId, latest.revision, latest.plan.summary);
  return turnResult(assistantMessageId);
}

/**
 * Runs the agent's animation-drafting loop and ends the turn with a candidate for the user to keep.
 *
 * The model applies operations, reads back what they compiled to, and revises until it is happy.
 * Nothing is persisted until it finishes: the working document lives in this function, so a
 * rejected timing costs one tool call rather than a whole re-planning run.
 */
export async function executeAnimationTurn(
  job: typeof generationJobs.$inferSelect,
  sticker: typeof stickers.$inferSelect,
  sourceMessage: typeof chatMessages.$inferSelect,
  base: StickerDocument,
  activeRevision: typeof stickerRevisions.$inferSelect,
  instruction: string,
  history: string,
  targetLayerId: string | undefined,
  /** The images the user attached to this turn. Shown to the model; nothing here is drawn. */
  attachedImages: Array<{ bytes: Uint8Array; mimeType: string }>,
  toolCallId: string | undefined,
): Promise<AiTurnResult> {
  const db = await getDatabase();
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "planning_animation", progress: 0.35 });

  // Deterministic, so a workflow replay hands the model the same id it used before. Opaque to the
  // model, which only ever echoes it back.
  const animationId = derivedAssetId(job.id, "animation");
  let working: StickerDocument | undefined;
  /**
   * The operation set the working document was built from.
   *
   * Kept so a single-layer edit can be expressed as a change to this list rather than as a patch on
   * the document: the draft stays `base` plus one list of operations, which is what makes every
   * revision independently reproducible.
   */
  let landed: StickerOperationV1[] = [];
  let revision = 0;
  let snapshot = 0;
  // One transcript row per call, retries included.
  const nextLabel = toolCallLabeller();
  // Everything the model did not author. Telling it to fix a cancelled job or a vanished asset with
  // `update_animation` would only spend the loop's step budget, so these stop the loop instead.
  const abort = (error: unknown): never => { throw new TurnAbort(error); };
  // `beginToolCall` refuses to open a row on a job that is no longer running, and it says so with an
  // ordinary Error. Left unclassified that reads as a repairable complaint, so a cancelled turn
  // would be answered with advice the model would keep trying to act on.
  const openCall = async (toolName: StickerToolName): Promise<string> => {
    try {
      return await beginToolCall(job, toolName, undefined, nextLabel(toolName));
    } catch (error) {
      return abort(error);
    }
  };

  const land = async (operations: StickerOperationV1[]) => {
    await assertJobStillRunning(job.id).catch(abort);
    // Repairable: everything below is the model's own work, so it throws straight through to the
    // tool body and comes back as text it can act on.
    for (const operation of operations) {
      validatePlannedAnimationOperation(operation);
      if (targetLayerId) assertTargetedAnimationOperation(operation, targetLayerId);
    }
    // Applied to the base, never to the previous attempt: an update restates the whole animation, so
    // a repair cannot inherit half of the timing that was rejected.
    const document = applyStickerOperationsV1(base, operations);
    await assertDocumentAssetsOwned(document, job.ownerId, sticker.id).catch(abort);
    working = document;
    landed = operations;
    revision += 1;
    snapshot += 1;
    await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot, document }).catch(abort);
    return { animationId, revision, document };
  };

  const session: AnimationDraftingSession = {
    // The draft once one exists, the base document before that — so a look taken before the first
    // operation shows the sticker as it stands rather than failing.
    renderSticker: async () => {
      // Opened as a tool row like every other call, so the transcript shows the agent stopping to
      // look. It is the one call that changes nothing, which is exactly why it is worth showing:
      // otherwise a turn that spent two steps reviewing reads as a turn that stalled.
      const call = await openCall("view_sticker");
      try {
        const render = await renderWorkingDocument(working ?? base, job.ownerId);
        await finishToolCall(job, call, "complete", render);
        return render;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    createAnimation: async (operations) => {
      const call = await openCall("create_animation");
      try {
        if (working) throw new Error(`An animation already exists (${animationId}); use update_animation to change it`);
        const state = await land(operations);
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    updateAnimation: async (_animationId, operations) => {
      const call = await openCall("update_animation");
      try {
        if (!working) throw new Error("There is no animation to update yet; call create_animation first");
        const state = await land(operations);
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    editLayerAnimation: async (_animationId, layerId, operations) => {
      const call = await openCall("edit_layer_animation");
      try {
        if (!working) throw new Error("There is no animation to edit yet; call create_animation first");
        if (!base.layers.some((layer) => layer.id === layerId)) {
          throw new Error(
            `There is no layer ${layerId} on this sticker; its layers are ${base.layers.map((layer) => layer.id).join(", ")}`,
          );
        }
        // The scope is the whole point of the tool: an operation aimed elsewhere would silently
        // survive the swap below as if it had been part of this layer's motion all along.
        for (const operation of operations) {
          if (animationOperationLayerId(operation) !== layerId) {
            throw new Error(
              `edit_layer_animation only changes ${layerId}; use update_animation to change any other layer`,
            );
          }
        }
        // This layer's operations are replaced, every other layer's — and the document-level ones,
        // which name no layer — are carried forward, and the merged set is re-applied to the base.
        const kept = landed.filter((operation) => animationOperationLayerId(operation) !== layerId);
        const state = await land([...kept, ...operations]);
        await finishToolCall(job, call, "complete", state);
        return state;
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
    finalizeAnimation: async () => {
      const call = await openCall("finalize_animation");
      try {
        if (!working) throw new Error("There is no animation to finalize yet; call create_animation first");
        await finishToolCall(job, call, "complete", { animationId, revision, document: working });
        return { animationId, revision, document: working };
      } catch (error) {
        await finishToolCall(job, call, "failed", error);
        throw error;
      }
    },
  };

  const result = await getAiProvider().animateSticker(
    { document: base, instruction, history, presetGuidance: creationPresetGuidance(sticker.creationPresets),
      presetReferences: await creationPresetReferences(sticker.creationPresets), targetLayerId, references: attachedImages },
    session,
  );

  // Nothing landed at all: there is no motion to show and no reason to think a replay would find
  // any, so end the turn rather than publishing the base document back as a candidate.
  if (!working) throw new FatalError("The animation planner produced no usable motion");
  // Before the warning below, so a turn the user stopped is not also reported as a model that ran
  // out of steps.
  await assertJobStillRunning(job.id);
  // The loop can also stop on its step cap, or because finalize_animation itself threw. A candidate
  // the user can look at and reject beats a dead turn, so ship whatever motion actually landed.
  if (!result?.finalized) {
    console.warn("Finalizing an unfinished animation loop", { jobId: job.id, stickerId: sticker.id, revision });
  }
  const document = working;

  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision.id,
    // Animation adds no new artwork, so the base revision's images carry over untouched.
    masterAssetId: activeRevision.masterAssetId ?? undefined,
    previewAssetId: activeRevision.previewAssetId ?? undefined,
  });
  await finishToolCall(job, toolCallId);
  const content = await showStickerThroughTool(job, revisionId, document.kind, instruction, history);
  const assistantMessageId = await insertAssistantMessage(job, content, "animation", revisionId);
  const turn = await turnResult(assistantMessageId, revisionId);
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { snapshot: snapshot + 1, revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assistantMessage: turn.assistantMessage,
  });
  return turn;
}
