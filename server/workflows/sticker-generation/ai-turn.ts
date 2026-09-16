// The router: one turn's worth of agent work, from reading the transcript to deciding which
// of the turn kinds above should run.

import { and, asc, desc, eq, inArray, ne } from "drizzle-orm";
import { FatalError } from "workflow";
import { withAiApiCostRecorder, withAiStepUsageReporter } from "@/lib/ai/cost";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, chatThreads, generationJobs, stickerRevisions, stickers } from "@/lib/db/schema";
import { getAiProvider, type AiPlanVisual, type AiSequenceAsset } from "@/lib/ai/gateway";
import { describeError, traceEvent, traceSpan } from "@/lib/observability/trace";
import { appendGenerationEvent } from "@/lib/services/events";
import { generationExecutionContext, latestRetryableGeneration } from "@/lib/services/generation-retry";
import { currentPendingPlan, latestPlanConcept, stickerHasPlan } from "@/lib/services/plans";
import { assertValidAnimationBase, createCandidateRevision, isValidAnimationBase } from "@/lib/services/stickers";
import { getObjectStore } from "@/lib/storage/r2";
import { recordJobApiCost } from "@/lib/subscription/credits";
import { addLayerBesideExisting, emptyDocument, generateAndStoreAsset, selectImageReferences } from "./asset-generation";
import { executePlanBuildTurn, loadPlanAnimationSummary, loadPlanVisualReference } from "./build-turns";
import { executeEditTurn } from "./edit-turns";
import { executeAnimationTurn, executePlanTurn } from "./plan-turns";
import { assertDocumentAssetsOwned, assertJobStillRunning, beginToolCall, boundedTranscript, finishToolCall, insertAssistantMessage, quickCaption, renderWorkingDocument, reportTurnTokens, reportTurnWork, showStickerThroughTool, turnResult } from "./turn-context";
import type { AiTurnResult, StickerToolName } from "./turn-context";

export async function executeAiJob(jobId: string): Promise<AiTurnResult> {
  // The step boundary is also the retry boundary, and nothing else prints why an attempt failed: the
  // workflow's catch only runs once the runtime has given up, so a turn that is being replayed —
  // regenerating its image every time — otherwise reports nothing at all. Name the error on the way
  // out, with the frame that threw it, since several of these messages appear in more than one place.
  try {
    const db = await getDatabase();
    // The owner is what an event stream is keyed on, and both meters below need it on every call.
    const ownerId = (await db.select({ ownerId: generationJobs.ownerId }).from(generationJobs)
      .where(eq(generationJobs.id, jobId)).then(firstRow))?.ownerId;
    // Both meters are best effort: what the chat draws while it waits must never be the reason a
    // turn that has already been paid for fails.
    const meter = async (report: (owner: string) => Promise<void>) => {
      if (ownerId === undefined) return;
      try {
        await report(ownerId);
      } catch (error) {
        traceEvent("turnMeter:skipped", { jobId, error: describeError(error) });
      }
    };
    return await withAiApiCostRecorder(
      async (event) => {
        await recordJobApiCost(db, jobId, event);
        await meter((owner) => reportTurnWork(db, jobId, owner, event));
      },
      () => withAiStepUsageReporter(
        (outputTokens) => meter((owner) => reportTurnTokens(db, jobId, owner, outputTokens)),
        () => runAiTurn(jobId),
      ),
    );
  } catch (error) {
    traceEvent("executeAiJobStep:fail", {
      jobId,
      error: describeError(error),
      at: error instanceof Error
        ? error.stack?.split("\n").slice(1, 4).map((line) => line.trim())
        : undefined,
    });
    throw error;
  }
}

async function runAiTurn(jobId: string): Promise<AiTurnResult> {
  const db = await getDatabase();
  const attempt = await db.select().from(generationJobs).where(eq(generationJobs.id, jobId)).then(firstRow);
  const execution = attempt ? await generationExecutionContext(db, attempt) : undefined;
  const job = attempt && execution ? {
    ...attempt,
    kind: execution.original.kind,
    sourceMessageId: execution.original.sourceMessageId,
    quick: execution.original.quick,
  } : undefined;
  traceEvent("executeAiJobStep:context", { jobId, kind: job?.kind, state: job?.state, attempts: job?.attempts });
  if (!job || !job.sourceMessageId) throw new Error("Generation job or source message not found");
  if (job.state !== "running") throw new Error(`Generation job is not running (${job.state})`);
  const [sticker, sourceMessage] = await Promise.all([
    db.select().from(stickers).where(and(eq(stickers.id, job.stickerId), eq(stickers.ownerId, job.ownerId))).then(firstRow),
    db.select().from(chatMessages).where(eq(chatMessages.id, job.sourceMessageId)).then(firstRow),
  ]);
  if (!sticker || !sourceMessage) throw new Error("Sticker generation context not found");
  if (sticker.status === "deleting") throw new Error("Sticker deletion is in progress");
  const existingAssistant = await db.select({ id: chatMessages.id, revisionId: chatMessages.revisionId }).from(chatMessages).where(and(
    eq(chatMessages.jobId, job.id),
    eq(chatMessages.role, "assistant"),
  )).then(firstRow);
  if (existingAssistant) {
    // The turn already produced its reply on an earlier attempt, so this run is a replay of work
    // that landed. Says outright that the step is being executed more than once.
    traceEvent("executeAiJobStep:alreadyAnswered", { jobId, assistantMessageId: existingAssistant.id });
    return turnResult(existingAssistant.id, existingAssistant.revisionId ?? undefined);
  }
  const thread = await db.select().from(chatThreads).where(eq(chatThreads.stickerId, sticker.id)).then(firstRow);
  if (!thread) throw new Error("Chat thread not found");
  // Two reads rather than one capped read. A single capped read spends most of its rows on tool
  // calls — an edit turn writes one per tool it runs — so a 200-row window on a busy thread can
  // reach back only a handful of real turns, and the chat the planner needs is what falls off the
  // end. Chat rows are therefore read without a cap, and the cap stays on the machinery.
  const [chatRows, toolRows] = await Promise.all([
    db.select().from(chatMessages)
      .where(and(eq(chatMessages.threadId, thread.id), ne(chatMessages.kind, "status")))
      .orderBy(asc(chatMessages.sequence)),
    db.select().from(chatMessages)
      .where(and(eq(chatMessages.threadId, thread.id), eq(chatMessages.kind, "status")))
      .orderBy(desc(chatMessages.sequence)).limit(200),
  ]);
  const transcript = [...chatRows, ...toolRows].sort((left, right) => left.sequence - right.sequence);
  const retryStep = execution?.retryStepId
    ? transcript.find((message) => message.id === execution.retryStepId)
    : undefined;
  const recoveryNote = execution?.original.id !== job.id
    ? `\n\nResuming the original ${job.kind} generation. Preserve its request, approved plan, poses, motion and references. Reuse completed work and finish the remaining steps.${retryStep ? ` The user selected step: ${retryStep.content}.` : ""}`
    : "";
  const history = boundedTranscript(transcript) + recoveryNote;
  // The planner is prompted with this one instead. Everything else in a turn works from the document
  // in front of it, so a digest of the older conversation costs it little; a plan is a brief, and the
  // brief is spread across the whole thread — the character named in the first message, the style
  // turned down in the third, the "make it a cat" in the sixth. See `keepChatVerbatim`.
  const planHistory = boundedTranscript(transcript, 24_000, { keepChatVerbatim: true }) + recoveryNote;
  traceEvent("runAiTurn:transcript", {
    jobId,
    chatRows: chatRows.length,
    toolRows: toolRows.length,
    historyCharacters: history.length,
    planHistoryCharacters: planHistory.length,
  });
  const attachments = await db.select({
    attachment: chatAttachments,
    asset: assets,
  }).from(chatAttachments)
    .innerJoin(assets, eq(chatAttachments.assetId, assets.id))
    .where(eq(chatAttachments.messageId, sourceMessage.id))
    .orderBy(asc(chatAttachments.position));

  const baseRevisionId = sourceMessage.baseRevisionId ?? sticker.activeRevisionId;
  const activeRevision = baseRevisionId
    ? await db.select().from(stickerRevisions).where(and(eq(stickerRevisions.id, baseRevisionId), eq(stickerRevisions.stickerId, sticker.id))).then(firstRow)
    : undefined;
  const activeDocument = activeRevision ? StickerDocumentSchema.parse(activeRevision.documentJson) : undefined;
  if (activeDocument) await assertDocumentAssetsOwned(activeDocument, job.ownerId, sticker.id);
  const objectStore = getObjectStore();
  const referenceRows = attachments.filter((row) => row.attachment.kind === "reference");
  /**
   * Every reference the user has attached anywhere in this project, oldest first.
   *
   * Read thread-wide rather than per-message because an attachment does not stop being what the
   * sticker is *of* on the turn after it arrives. Scoping it to the source message is what let a
   * turn whose whole request was "add some text" replace the user's own captured footage with a
   * generated lookalike: with no capture in `sequenceAssets`, a `sequence` source was not merely
   * invisible to the planner but illegal, so describing the person in a prompt was the only move
   * left open to it.
   */
  const threadReferenceRows = await db.select({
    attachment: chatAttachments,
    asset: assets,
    sequence: chatMessages.sequence,
  }).from(chatAttachments)
    .innerJoin(assets, eq(chatAttachments.assetId, assets.id))
    .innerJoin(chatMessages, eq(chatAttachments.messageId, chatMessages.id))
    .where(and(
      eq(chatMessages.threadId, thread.id),
      eq(chatAttachments.kind, "reference"),
      eq(assets.state, "ready"),
      eq(assets.ownerId, job.ownerId),
    ))
    .orderBy(asc(chatMessages.sequence), asc(chatAttachments.position));
  /** Newest first, and never this turn's own rows — those already travel as attachments. */
  const carriedReferenceRows = threadReferenceRows
    .filter((row) => row.attachment.messageId !== sourceMessage.id)
    .reverse();
  /**
   * A capture, as opposed to a photo: an atlas whose grid the plan has to copy exactly.
   *
   * Captures ride in as ordinary `reference` attachments — the atlas is a PNG, so nothing about the
   * wire format needed widening — and are told apart by their asset kind. The grid comes off the
   * asset row rather than out of the image, because a sprite sheet cannot describe itself.
   */
  const capturedFrames = (asset: typeof assets.$inferSelect): AiSequenceAsset | undefined => (
    asset.kind === "sequence"
      && asset.frameCount && asset.fps
      && asset.sequenceColumns && asset.sequenceRows
      ? {
        assetId: asset.id,
        columns: asset.sequenceColumns,
        rows: asset.sequenceRows,
        frameCount: asset.frameCount,
        frameRate: asset.fps,
      }
      : undefined
  );
  // This turn's captures first so a fresh one outranks an old one, then everything the project has
  // carried. These are numbers rather than pixels, so listing them all costs the prompt almost
  // nothing and is what keeps every capture a legal source for as long as the project lasts.
  const sequenceAssets: AiSequenceAsset[] = [];
  const seenCaptureIds = new Set<string>();
  for (const row of [...referenceRows, ...carriedReferenceRows]) {
    const capture = capturedFrames(row.asset);
    if (!capture || seenCaptureIds.has(capture.assetId)) continue;
    seenCaptureIds.add(capture.assetId);
    sequenceAssets.push(capture);
  }
  /**
   * The one carried attachment the planner is shown, on top of anything attached this turn.
   *
   * A capture wins over a photo because a capture *is* the sticker's subject rather than a reference
   * for one. Only one is shown: the prior-art budget also has to cover the current render and the
   * resting concept and animation summary, and those say things no attachment can.
   */
  const carriedSubjectRow = carriedReferenceRows.find((row) => capturedFrames(row.asset))
    ?? carriedReferenceRows[0];
  let attachedImagesPromise: Promise<Array<{ bytes: Uint8Array; mimeType: string }>> | undefined;
  /**
   * What the user actually attached to this turn, and nothing else.
   *
   * Kept apart from `loadReferenceImages` below because the two answer different questions. This is
   * the set the reasoning models are *shown* — so it has to mean "the pictures the user handed over",
   * not "the pictures a redraw happens to be given".
   */
  const loadAttachedImages = () => {
    attachedImagesPromise ??= Promise.all(referenceRows.map(async (row) => {
      const object = await objectStore.get(row.asset.r2Key);
      return { bytes: object.bytes, mimeType: row.asset.mimeType };
    }));
    return attachedImagesPromise;
  };
  let priorArtPromise: Promise<AiPlanVisual[]> | undefined;
  let latestVisualPlanPromise: ReturnType<typeof latestPlanConcept> | undefined;
  const loadLatestVisualPlan = () => {
    latestVisualPlanPromise ??= (async () =>
      await currentPendingPlan(db, job.ownerId, sticker.id)
        ?? await latestPlanConcept(db, job.ownerId, sticker.id)
    )();
    return latestVisualPlanPromise;
  };
  let latestPlanReferencePromise: Promise<{
    planId: string;
    image: { bytes: Uint8Array; mimeType: string };
  } | undefined> | undefined;
  const loadLatestPlanReference = () => {
    latestPlanReferencePromise ??= (async () => {
      const plan = await loadLatestVisualPlan();
      if (!plan) return undefined;
      return {
        planId: plan.id,
        image: await loadPlanVisualReference(plan, job.ownerId, sticker.id),
      };
    })();
    return latestPlanReferencePromise;
  };
  /**
   * The pictures of the project the planner is shown, on top of anything the user attached.
   *
   * These are best-effort. A render can fail on a document whose artwork has been swept, and a plan's
   * static reference can be missing or unreadable; neither is a reason to fail a planning turn that
   * would otherwise succeed, so each failure is traced and the picture is simply left out.
   */
  const loadPlanPriorArt = () => {
    priorArtPromise ??= (async () => {
      const visuals: AiPlanVisual[] = [];
      // First, because it outranks anything the planner drew: this is the user's own material, and
      // on a turn with no fresh attachment it is the only sight of the subject there is.
      if (carriedSubjectRow) {
        const capture = capturedFrames(carriedSubjectRow.asset);
        try {
          const object = await getObjectStore().get(carriedSubjectRow.asset.r2Key);
          visuals.push({
            label: capture
              ? "footage the user captured of themselves earlier in this project, already cut out and "
                + `laid out as a contact sheet of ${capture.frameCount} frames read left to right, top `
                + "to bottom. It is one subject moving, not several subjects. It is still listed below "
                + "as a sequence source you can use, and it is the sticker's subject"
              : "a photo the user attached earlier in this project, still the reference for who or "
                + "what this sticker is of",
            image: { bytes: object.bytes, mimeType: carriedSubjectRow.asset.mimeType },
          });
        } catch (error) {
          traceEvent("plan:priorArt:carriedUnreadable", {
            jobId,
            assetId: carriedSubjectRow.asset.id,
            error: describeError(error),
          });
        }
      }
      if (activeDocument) {
        try {
          const render = await renderWorkingDocument(activeDocument, job.ownerId);
          visuals.push({
            // Says which of the two shapes the picture is, because an animated render is a contact
            // sheet and a planner that reads one as a single composition sees a sticker with the
            // same subject drawn six times. The review-render caveat rides along for the same
            // reason the `view_sticker` tool carries it: this is drawn by the server, not by the app
            // that ships the sticker, so it is evidence about layout and colour and not about
            // kerning or a few pixels of curve.
            label: render.times.length > 1
              ? "the sticker as it stands now, as a contact sheet of frames sampled across its "
                + "animation and read left to right, top to bottom — one sticker, not several. "
                + "It is a server-side review render, so judge layout, coverage and colour from it "
                + "and not fine typography"
              : "the sticker exactly as it looks right now, which is what the user is looking at. "
                + "It is a server-side review render, so judge layout, coverage and colour from it "
                + "and not fine typography",
            image: { bytes: render.bytes, mimeType: render.mimeType },
          });
        } catch (error) {
          traceEvent("plan:priorArt:renderFailed", { jobId, error: describeError(error) });
        }
      }
      try {
        const previousPlan = await loadLatestPlanReference();
        if (previousPlan) {
          visuals.push({
            label: "the static reference the previous plan produced, which the user has already seen",
            image: previousPlan.image,
          });
        }
      } catch (error) {
        traceEvent("plan:priorArt:conceptUnavailable", {
          jobId,
          error: describeError(error),
        });
      }
      try {
        const plan = await loadLatestVisualPlan();
        const summary = plan && await loadPlanAnimationSummary(plan, job.ownerId, sticker.id);
        if (summary) {
          visuals.push({
            label: `the illustrated animation summary shown with plan "${plan.planJson.title}" `
              + `(revision ${plan.revision}, ${plan.state}). Its labelled panels explain the planned `
              + "motions, poses and expressions. Use it to understand references such as 'the second pose' "
              + "or 'that expression'. It is a storyboard, not the finished sticker: do not copy its "
              + "panels, labels, arrows or background into the artwork",
            image: summary,
          });
        }
      } catch (error) {
        traceEvent("plan:priorArt:animationSummaryUnavailable", { jobId, error: describeError(error) });
      }
      traceEvent("plan:priorArt", { jobId, count: visuals.length });
      return visuals;
    })();
    return priorArtPromise;
  };
  let referenceImagesPromise: Promise<Array<{ bytes: Uint8Array; mimeType: string }>> | undefined;
  const loadReferenceImages = () => {
    referenceImagesPromise ??= (async () => {
      const userReferenceImages = await loadAttachedImages();
      const attachedAssetIds = new Set(referenceRows.map((row) => row.asset.id));
      /**
       * Everything the user has handed this project on an earlier turn, newest first.
       *
       * This is what keeps a face a face. The image model is the only thing in the pipeline that
       * ever sees a photograph, and it used to see one only on the turn it was uploaded: a later
       * turn with no attachment and no built document rendered its concept from the plan's prose
       * alone. A written description cannot carry a likeness — "short tousled black hair,
       * rectangular dark grey glasses, fair warm skin" describes thousands of people — so the
       * subject was quietly reinvented on every turn that did not re-upload them.
       *
       * Unreadable ones are skipped rather than thrown. A carried reference is an improvement on
       * having none, and failing a turn because a photo from six turns ago has gone from the store
       * would be a worse trade than rendering without it.
       */
      const carriedReferenceImages = (await Promise.all(
        carriedReferenceRows
          .filter((row) => !attachedAssetIds.has(row.asset.id))
          .slice(0, Math.max(0, 8 - userReferenceImages.length))
          .map(async (row) => {
            try {
              const object = await objectStore.get(row.asset.r2Key);
              return [{ bytes: object.bytes, mimeType: row.asset.mimeType }];
            } catch (error) {
              traceEvent("references:carried:unreadable", {
                jobId,
                assetId: row.asset.id,
                error: describeError(error),
              });
              return [];
            }
          }),
      )).flat();
      // A re-plan should preserve the artwork already on screen as faithfully as a newly attached
      // photo. Fill any reference slots the user did not occupy with the current document's image
      // layers, in layer order, and never send the same asset twice.
      const carriedAssetIds = new Set(carriedReferenceRows.map((row) => row.asset.id));
      const spentSlots = userReferenceImages.length + carriedReferenceImages.length;
      const reusableReferenceIds = activeDocument?.layers.flatMap((layer) => (
        layer.type === "image" && !attachedAssetIds.has(layer.assetId) && !carriedAssetIds.has(layer.assetId)
          ? [layer.assetId]
          : []
      )).filter((id, index, all) => all.indexOf(id) === index).slice(0, Math.max(0, 8 - spentSlots)) ?? [];
      const reusableReferenceRows = reusableReferenceIds.length > 0
        ? await db.select().from(assets).where(and(
          eq(assets.ownerId, job.ownerId),
          eq(assets.stickerId, sticker.id),
          eq(assets.state, "ready"),
          inArray(assets.id, reusableReferenceIds),
        ))
        : [];
      const reusableById = new Map(reusableReferenceRows.map((asset) => [asset.id, asset]));
      const reusableReferenceImages = await Promise.all(reusableReferenceIds.flatMap((id) => {
        const asset = reusableById.get(id);
        return asset
          ? [objectStore.get(asset.r2Key).then((object) => ({ bytes: object.bytes, mimeType: asset.mimeType }))]
          : [];
      }));
      // This turn's attachments first, then what the project has carried, then its own artwork:
      // the closer a picture is to what the user just handed over, the more it should weigh.
      return [...userReferenceImages, ...carriedReferenceImages, ...reusableReferenceImages].slice(0, 8);
    })();
    return referenceImagesPromise;
  };
  const existingRevision = await db.select().from(stickerRevisions).where(and(
    inArray(stickerRevisions.id, [...new Set([job.id, execution!.original.id])]),
    eq(stickerRevisions.stickerId, sticker.id),
  )).orderBy(desc(stickerRevisions.createdAt)).then(firstRow);
  if (existingRevision) {
    const existingDocument = StickerDocumentSchema.parse(existingRevision.documentJson);
    await assertJobStillRunning(job.id);
    // If generation finished and only its presentation failed, attach the already-built document
    // to the new attempt without paying for its artwork again.
    const revisionId = existingRevision.id === job.id ? existingRevision.id : await createCandidateRevision(db, {
      ownerId: job.ownerId, stickerId: sticker.id, sourceMessageId: sourceMessage.id,
      id: job.id, document: existingDocument, parentRevisionId: existingRevision.parentRevisionId ?? undefined,
      masterAssetId: existingRevision.masterAssetId ?? undefined,
      previewAssetId: existingRevision.previewAssetId ?? undefined,
    });
    const kind = existingDocument.kind === "animated" && (sourceMessage.kind === "animation" || job.kind === "compose")
      ? "animation"
      : sourceMessage.kind === "image"
        ? "image"
        : "image_edit";
    const primaryToolCallId = await beginToolCall(
      job,
      kind === "animation" ? "animate-sticker" : kind === "image" ? "generate-sticker" : "edit-sticker",
      revisionId,
    );
    await finishToolCall(job, primaryToolCallId);
    const content = await showStickerThroughTool(job, revisionId, existingDocument.kind, sourceMessage.content, history);
    const assistantMessageId = await insertAssistantMessage(job, content, kind, revisionId);
    return turnResult(assistantMessageId, revisionId);
  }

  if (job.kind === "compose") {
    return executePlanBuildTurn(job, sticker, sourceMessage, history, activeRevision, await loadReferenceImages());
  }

  // Pending plans stay in planning until the user confirms or cancels them. Bypass the general
  // router so ordinary feedback cannot generate a sticker or edit the existing document.
  const pendingPlan = await currentPendingPlan(db, job.ownerId, sticker.id);
  if (job.kind === "plan" || pendingPlan) {
    return executePlanTurn(
      job,
      sticker,
      thread.id,
      sourceMessage.content,
      pendingPlan
        ? `${planHistory}\n\nCurrent pending plan (not yet accepted or rejected). Revise this design according to the user's follow-up, preserving everything else:\n${JSON.stringify(pendingPlan.planJson)}`
        : planHistory,
      activeDocument,
      await loadReferenceImages(),
      await loadAttachedImages(),
      await loadPlanPriorArt(),
      sequenceAssets,
      await beginToolCall(job, "plan-sticker"),
    );
  }

  if (job.kind !== "image" && job.kind !== "edit" && job.kind !== "animation" && job.kind !== "chat") {
    throw new Error(`Unsupported AI job kind: ${job.kind}`);
  }
  let effectiveKind: "image" | "edit" | "animation" = job.kind === "chat" ? "edit" : job.kind;
  let instruction = sourceMessage.content;
  let targetLayerId = sourceMessage.targetLayerId ?? undefined;
  let imagePlacement = sourceMessage.imagePlacement;
  let usePlanImage = false;
  let primaryToolCallId: string | undefined;
  /**
   * Whether the turn is a change to the sticker as a whole, and so belongs in the edit loop.
   *
   * `generate-image` is deliberately not: it is a single fully specified action — one new element,
   * its own layer — so it stays on the deterministic path below rather than paying for an
   * orchestrator loop to decide the obvious.
   */
  let editsThroughLoop = job.kind === "edit" && !job.quick;
  let video: { layerId: string; motion: string; durationSeconds: number } | undefined;
  /**
   * Whether this animated project still has to be designed as layers before anything is drawn.
   *
   * The kind is a choice the user made before typing a word, and only layers can be keyframed: a
   * single flat image is a dead end that no later turn can animate. So an animated project that has
   * never been planned is planned first, whatever the router made of the words — the router reads
   * the request, and this is a property of the project.
   */
  const hasPlan = await stickerHasPlan(db, job.ownerId, sticker.id);
  const mustPlanFirst = sticker.kind === "animated" && !activeDocument && !hasPlan;

  // A preset submitted from the live plan is an explicit re-plan, including after a build.
  // The user message kind persists this intent for retries; no router guess is needed.
  if (sourceMessage.kind === "plan" && sourceMessage.role === "user") {
    return executePlanTurn(job, sticker, thread.id, instruction, planHistory, activeDocument,
      await loadReferenceImages(), await loadAttachedImages(), await loadPlanPriorArt(), sequenceAssets,
      await beginToolCall(job, "plan-sticker"));
  }

  if (job.kind === "chat") {
    // The router, the images it reads and the history it reads them against take seconds, and
    // until one of them opens a tool row the turn has said nothing at all. That silence is the
    // longest stretch of an ordinary turn where the only thing on screen is an animation, so it
    // gets a stage of its own rather than being the gap before the first one.
    await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
      stage: "reading_request",
      progress: 0.05,
    });
    // Fetched before the span rather than inside it, so the router's own latency stays the model's
    // and not the object store's.
    const [attachedImages, routerPriorArt] = await Promise.all([
      loadAttachedImages(),
      loadPlanPriorArt(),
    ]);
    const retryableGeneration = execution?.original.id === job.id
      ? await latestRetryableGeneration(db, job)
      : undefined;
    const action = execution?.routedAction ?? await traceSpan("routeChatTurn", { jobId }, () => getAiProvider().routeChatTurn({
      instruction: sourceMessage.content,
      history,
      stickerKind: sticker.kind,
      document: activeDocument,
      hasPlan,
      attachmentCount: referenceRows.length,
      references: attachedImages,
      priorArt: routerPriorArt,
      retryableGeneration,
    }));
    traceEvent("routeChatTurn:routed", { jobId, action: action.type });
    if (action.type === "retry_generation") {
      if (!retryableGeneration || (action.stepId && !retryableGeneration.steps.some(
        (step) => step.id === action.stepId && step.status !== "complete",
      ))) throw new FatalError("The requested generation step is not available to retry");
      // A durable link, just like the Retry button's queued event. The current message stays the
      // source of this attempt for streaming/completion; execution resolves the original request.
      await assertJobStillRunning(job.id);
      await appendGenerationEvent(db, job.id, job.ownerId, "queued", {
        retryOfJobId: retryableGeneration.jobId, retryStepId: action.stepId,
      });
      return runAiTurn(job.id);
    }
    if (!execution?.routedAction) {
      // Save the resolved action before any image, edit, animation or plan work can fail. A retry
      // must not ask the router to interpret the short retry message as a fresh generation.
      await appendGenerationEvent(db, job.id, job.ownerId, "progress", { checkpoint: "routed_chat", action });
    }
    // Motion is keyframed onto a live revision of this sticker — the one the user kept, or a
    // candidate descended from it. The router reads their words, not the revision's state, so it
    // cannot know whether the base still qualifies, and by the time it has chosen the turn is
    // already in the transcript. Say what is missing instead of failing the job on a rule the user
    // was never shown.
    if (action.type === "animate" && !await isValidAnimationBase(db, sticker, activeRevision)) {
      console.warn("Declined a routed animate turn", {
        jobId: job.id,
        stickerId: sticker.id,
        sourceMessageId: sourceMessage.id,
        sourceMessageBaseRevisionId: sourceMessage.baseRevisionId,
        stickerActiveRevisionId: sticker.activeRevisionId,
        resolvedBaseRevisionId: baseRevisionId,
        targetLayerId: action.targetLayerId,
      });
      const declinedCallId = await beginToolCall(job, "reply");
      await finishToolCall(job, declinedCallId);
      return turnResult(await insertAssistantMessage(
        job,
        activeDocument
          ? "That version isn’t the one I’m working from any more. Ask me again and I’ll animate the"
            + " sticker that’s on screen now."
          : "There’s no sticker to animate yet. Tell me what you want it to look like and I’ll draw"
            + " it first.",
        "text",
      ));
    }
    // An unplanned animated project cannot be served by drawing: whatever words the router read,
    // one flat image would leave the user with the static sticker they did not pick, and no later
    // turn could rescue it. Only the artwork-creating routes are redirected — a question still gets
    // its answer, and `show` still shows.
    if (mustPlanFirst && (action.type === "generate" || action.type === "generate_image")) {
      traceEvent("routeChatTurn:forcedPlan", { jobId, action: action.type });
      return executePlanTurn(
        job,
        sticker,
        thread.id,
        action.instruction,
        planHistory,
        undefined,
        await loadReferenceImages(),
        await loadAttachedImages(),
        await loadPlanPriorArt(),
        sequenceAssets,
        await beginToolCall(job, "plan-sticker"),
      );
    }
    const toolName: StickerToolName = action.type === "generate_video"
      ? "generate-video"
      : action.type === "generate"
      ? "generate-sticker"
      : action.type === "generate_image"
        ? "generate-image"
        : action.type === "edit"
          ? "edit-sticker"
          : action.type === "animate"
            ? "animate-sticker"
            : action.type === "plan"
              ? "plan-sticker"
              : action.type === "show"
                ? "show-sticker"
                : "reply";
    primaryToolCallId = await beginToolCall(job, toolName, action.type === "show" ? activeRevision?.id : undefined);
    if (action.type === "plan") {
      return executePlanTurn(
        job,
        sticker,
        thread.id,
        action.instruction,
        planHistory,
        activeDocument,
        await loadReferenceImages(),
        await loadAttachedImages(),
        await loadPlanPriorArt(),
        sequenceAssets,
        primaryToolCallId,
      );
    }
    if (action.type === "reply") {
      await finishToolCall(job, primaryToolCallId);
      return turnResult(await insertAssistantMessage(job, action.message, "text"));
    }
    if (action.type === "show") {
      await finishToolCall(job, primaryToolCallId);
      if (!activeRevision || !activeDocument) {
        return turnResult(await insertAssistantMessage(job, "There is no sticker revision to show yet.", "text"));
      }
      const kind = activeDocument.kind === "animated" ? "animation" : "image";
      return turnResult(
        await insertAssistantMessage(job, action.caption, kind, activeRevision.id),
        activeRevision.id,
      );
    }
    // `generate-image` only means "another layer" when there is a document to add one to. On an
    // empty canvas it is an ordinary generation, and calling it an edit would label the transcript
    // turn `image_edit` and send the empty-document branch down the replace path for no reason.
    const addsLayer = action.type === "generate_image" && Boolean(activeDocument);
    effectiveKind = action.type === "animate"
      ? "animation"
      : action.type === "generate" || (action.type === "generate_image" && !addsLayer)
        ? "image"
        : "edit";
    instruction = action.instruction;
    usePlanImage = (action.type === "generate" || action.type === "generate_image" || action.type === "edit")
      && action.usePlanImage === true;
    targetLayerId = action.type === "edit" || action.type === "animate" ? action.targetLayerId : undefined;
    imagePlacement = action.type === "edit" ? action.imagePlacement : addsLayer ? "add" : "replace";
    video = action.type === "generate_video"
      ? { layerId: action.layerId, motion: action.instruction, durationSeconds: action.durationSeconds }
      : undefined;
    if (video && (!activeDocument || !activeRevision)) {
      throw new FatalError("Video generation requires an existing sticker");
    }
    if (video) targetLayerId = video.layerId;
    editsThroughLoop = Boolean(video) || (action.type === "edit" && !job.quick);
    await db.update(chatMessages).set({
      kind: effectiveKind === "animation" ? "animation" : effectiveKind === "edit" ? "image_edit" : "image",
      // Explicitly null: an undefined column is one drizzle leaves alone, which would strand the
      // target a superseded routing of this same message wrote on the row.
      targetLayerId: targetLayerId ?? null,
      imagePlacement,
    }).where(eq(chatMessages.id, sourceMessage.id));
  } else if (job.kind === "image" && mustPlanFirst) {
    // Project creation does not go through the chat router, so without this the very first prompt
    // would become one flat image — and a flat image has no separate parts to keyframe, so the
    // animated project the user asked for could never be anything but a static sticker. This used
    // to ask the router whether to plan and drew whenever it said no; the kind is the user's
    // standing choice, not a judgement call about their wording, so the plan is unconditional.
    traceEvent("executeAiJobStep:forcedPlan", { jobId, stickerId: sticker.id });
    return executePlanTurn(
      job,
      sticker,
      thread.id,
      instruction,
      planHistory,
      undefined,
      await loadReferenceImages(),
      await loadAttachedImages(),
      await loadPlanPriorArt(),
      sequenceAssets,
      await beginToolCall(job, "plan-sticker"),
    );
  } else {
    primaryToolCallId = await beginToolCall(
      job,
      job.kind === "animation" ? "animate-sticker" : job.kind === "image" ? "generate-sticker" : "edit-sticker",
    );
  }

  if (effectiveKind === "animation") {
    if (!activeDocument || activeDocument.kind !== "animated" || !activeRevision) {
      throw new FatalError("There is no animated sticker to add motion to");
    }
    await assertValidAnimationBase(db, sticker, activeRevision);
    if (targetLayerId && !activeDocument.layers.some((layer) => layer.id === targetLayerId)) {
      throw new FatalError("The requested animation layer does not exist");
    }
    return executeAnimationTurn(
      job,
      sticker,
      sourceMessage,
      activeDocument,
      activeRevision,
      instruction,
      history,
      targetLayerId,
      await loadAttachedImages(),
      primaryToolCallId,
    );
  }

  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "preparing_context", progress: 0.15 });
  const ordinaryReferenceImages = await loadReferenceImages();
  let referenceImages = ordinaryReferenceImages;
  if (usePlanImage) {
    const planReference = await loadLatestPlanReference();
    if (!planReference) throw new FatalError("The plan image is no longer available");
    referenceImages = [planReference.image, ...ordinaryReferenceImages].slice(0, 8);
  }

  const maskRow = attachments.find((row) => row.attachment.kind === "mask");

  // Everything that changes a sticker the user already has goes through the edit loop, which owns
  // the whole layer stack rather than one image. The exception is a masked edit: the user painted
  // the region and the client named the layer, so the request is already fully specified and a
  // single redraw is the whole of it.
  if (video && maskRow) throw new FatalError("Video generation does not support a painted mask");
  if (editsThroughLoop && effectiveKind === "edit" && activeDocument && activeRevision && !maskRow) {
    return executeEditTurn(
      job,
      sticker,
      sourceMessage,
      activeDocument,
      activeRevision,
      instruction,
      history,
      {
        targetLayerId,
        imagePlacement,
        references: referenceImages,
        requiredReferenceCount: usePlanImage ? 1 : 0,
        attachedImages: await loadAttachedImages(),
        video,
      },
      primaryToolCallId,
    );
  }

  targetLayerId = maskRow?.attachment.targetLayerId ?? targetLayerId;
  // Reached only when the id came from the request, which the chat endpoint has already validated
  // against this same base revision, or from a provider that did not reconcile its own routing. Both
  // are deterministic, so retrying replays the identical failure: fail the turn once instead.
  if (targetLayerId && !activeDocument?.layers.some((layer) => layer.type === "image" && layer.id === targetLayerId)) {
    throw new FatalError("The requested image layer does not exist");
  }
  const targetLayer = activeDocument?.layers.find((layer) => layer.type === "image" && (!targetLayerId || layer.id === targetLayerId));
  const targetAsset = targetLayer?.type === "image"
    ? await db.select().from(assets).where(and(eq(assets.id, targetLayer.assetId), eq(assets.ownerId, job.ownerId))).then(firstRow)
    : undefined;

  const replacesExistingImage = effectiveKind === "edit" && imagePlacement !== "add";
  const targetReference = replacesExistingImage && targetAsset
    ? await objectStore.get(targetAsset.r2Key)
      .then((object) => ({ bytes: object.bytes, mimeType: targetAsset.mimeType }))
    : undefined;
  const references = await selectImageReferences(
    instruction,
    history,
    [
      ...(targetReference
        ? [{ label: "current artwork being edited", image: targetReference, required: true }]
        : []),
      ...referenceImages.map((image, index) => ({
        label: usePlanImage && index === 0
          ? "approved plan image"
          : `original or carried reference ${index - (usePlanImage ? 1 : 0) + 1}`,
        image,
        required: usePlanImage && index === 0,
      })),
    ],
    job.quick,
  );
  const mask = maskRow
    ? await objectStore.get(maskRow.asset.r2Key).then((object) => ({ bytes: object.bytes, mimeType: maskRow.asset.mimeType }))
    : undefined;

  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "generating_image", progress: 0.4 });
  const assetId = execution?.original.id ?? job.id;
  await generateAndStoreAsset(job, sticker.id, {
    assetId,
    prompt: instruction,
    references,
    mask,
    conversationContext: history,
    // Explicitly reusing a plan image is also an edit, even on an otherwise empty canvas. Sending
    // the same bytes through the fresh-generation path treats them as inspiration and can redraw
    // the approved design instead of preserving it.
    mode: replacesExistingImage || usePlanImage ? "conversation_edit" : "generate",
  });

  let document: StickerDocument;
  if (!activeDocument) {
    document = emptyDocument(sticker.kind, assetId);
  } else if (imagePlacement === "add") {
    const layer = emptyDocument(activeDocument.kind, assetId).layers[0];
    layer.id = `image_${assetId.replaceAll("-", "").slice(0, 12)}`;
    layer.name = "Generated layer";
    document = addLayerBesideExisting(activeDocument, layer);
  } else {
    const imageLayer = targetLayer ?? activeDocument.layers.find((layer) => layer.type === "image");
    if (imageLayer?.type === "image") {
      document = applyStickerOperationsV1(activeDocument, [{ op: "replaceAsset", layerId: imageLayer.id, assetId }]);
    } else {
      document = addLayerBesideExisting(activeDocument, emptyDocument(activeDocument.kind, assetId).layers[0]);
    }
  }
  await assertJobStillRunning(job.id);
  const revisionId = await createCandidateRevision(db, {
    ownerId: job.ownerId,
    stickerId: sticker.id,
    sourceMessageId: sourceMessage.id,
    document,
    id: job.id,
    parentRevisionId: activeRevision?.id,
    masterAssetId: assetId,
    previewAssetId: assetId,
  });
  traceEvent("candidateRevision:created", { jobId, revisionId, layers: document.layers.length });
  await finishToolCall(job, primaryToolCallId);
  // A second model call, after the picture is already paid for and stored. If the step dies here the
  // artwork exists and the turn never finishes, so it gets its own span.
  //
  // Quick mode writes the line itself instead. The caption is a sentence about artwork the user is
  // already looking at, on a surface that shows no transcript at all — and it is a vision call, so
  // it routinely costs several times what the quick draw it describes cost. The transcript still
  // needs a message, because a turn without one is a turn the main app cannot render later.
  const content = job.quick
    ? quickCaption(effectiveKind)
    : await traceSpan(
      "showSticker",
      { jobId, revisionId },
      () => showStickerThroughTool(job, revisionId, document.kind, instruction, history),
    );
  const assistantMessageId = await insertAssistantMessage(job, content, effectiveKind === "edit" ? "image_edit" : "image", revisionId);
  const result = await turnResult(assistantMessageId, revisionId);
  await appendGenerationEvent(db, job.id, job.ownerId, "progress", { stage: "validating_candidate", progress: 0.85 });
  await appendGenerationEvent(db, job.id, job.ownerId, "document", { revisionId, document });
  await appendGenerationEvent(db, job.id, job.ownerId, "candidate", {
    revisionId,
    assistantMessageId,
    assetId,
    assistantMessage: result.assistantMessage,
  });
  traceEvent("executeAiJobStep:done", { jobId, revisionId, assistantMessageId });
  return result;
}
