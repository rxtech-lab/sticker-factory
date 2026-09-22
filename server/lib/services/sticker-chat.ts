import { currentBillingEnvironment } from "@/lib/subscription/client";
// Chat turns: starting one, retrying a failed one, and reading the transcript back.

import { quickGenerationPolicy, recordAppClipUsage } from "@/lib/subscription/app-clip";
import { DAILY_STICKER_GENERATION_ITEM, DAILY_STICKER_REFINEMENT_ITEM } from "@/lib/subscription/client";
import { consumeDailyUsage } from "@/lib/subscription/daily-usage";
import { and, asc, count, desc, eq, gt, inArray, isNull, lt, max, sql } from "drizzle-orm";
import type { PostChatMessageRequest } from "@/lib/contracts/api";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, chatAttachments, chatMessages, chatThreads, generationEvents, generationJobs, plans, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getReadyOwnedAssets } from "@/lib/services/assets";
import { editPlan, loadPlansByIds, serializePlan } from "@/lib/services/plans";
import { abandonHold, holdCreditsForJob } from "@/lib/subscription/credits";
import { jobCreditHold } from "@/lib/subscription/pricing";
import { assertValidAnimationBase, intentToJobKind } from "./sticker-documents";
import { AI_INPUT_ASSET_KINDS, AI_REFERENCE_MIME_TYPES, MAX_AI_INPUT_BYTES, assertOwnedSticker, isActiveJobConstraint } from "./sticker-summaries";

export async function createChatTurn(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PostChatMessageRequest,
  appClip = false,
  newSticker = false,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  if (request.planPoseUpdate && (sticker.kind !== "animated" || request.quick)) {
    throw new ApiError(422, "INVALID_POSE_PRESET", "Pose presets require a controllable animation plan");
  }
  // Shared OAuth identifies the account; the constrained operation selects its plan allowance.
  appClip = appClip || request.useQuickModeAllowance === true;
  if (appClip && (sticker.kind !== "static" || !request.quick ||
      !["generate", "edit"].includes(request.intent) || request.targetLayerId ||
      request.attachments.some((a) => a.kind !== "reference"))) {
    throw new ApiError(422, "APP_CLIP_QUICK_ONLY", "App Clip supports static quick generation and revision only.");
  }
  const thread = await db.select().from(chatThreads).where(and(
    eq(chatThreads.stickerId, stickerId),
    eq(chatThreads.ownerId, ownerId),
  )).then(firstRow);
  if (!thread) throw new ApiError(500, "CHAT_THREAD_MISSING", "Sticker chat thread is missing");

  const assetIds = request.attachments.map((attachment) => attachment.assetId);
  const attachedAssets = await getReadyOwnedAssets(db, ownerId, assetIds);
  const byId = new Map(attachedAssets.map((asset) => [asset.id, asset]));
  const baseRevision = request.baseRevisionId
    ? await db.select().from(stickerRevisions).where(and(
      eq(stickerRevisions.id, request.baseRevisionId),
      eq(stickerRevisions.stickerId, stickerId),
    )).then(firstRow)
    : sticker.activeRevisionId
      ? await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, sticker.activeRevisionId)).then(firstRow)
      : undefined;
  if (request.baseRevisionId && !baseRevision) {
    throw new ApiError(422, "INVALID_BASE_REVISION", "The selected base revision does not belong to this sticker");
  }
  const baseDocument = baseRevision ? StickerDocumentSchema.parse(baseRevision.documentJson) : undefined;
  if (request.intent === "animate") await assertValidAnimationBase(db, sticker, baseRevision);
  if (request.targetLayerId) {
    const target = baseDocument?.layers.find((layer) => layer.id === request.targetLayerId);
    if (!target) throw new ApiError(422, "INVALID_TARGET_LAYER", "The selected target layer does not exist in the base revision");
    // Any layer type is a legal edit target: an edit turn owns the whole layer stack, not just the
    // drawn artwork, so pointing at a caption to have it removed or reworded is an ordinary edit.
    // A masked edit is the one that still needs artwork underneath it, and the mask block below
    // enforces that on its own.
  }
  for (const attachment of request.attachments) {
    const asset = byId.get(attachment.assetId)!;
    if (attachment.kind === "mask" && asset.kind !== "mask") {
      throw new ApiError(422, "INVALID_MASK", "Mask attachments must reference a validated mask asset");
    }
    if (attachment.kind === "mask" && (
      (asset.mimeType !== "image/png" && asset.mimeType !== "image/webp")
      || !asset.hasAlpha
    )) {
      throw new ApiError(422, "INVALID_MASK", "Masks must be validated PNG or WebP images with alpha");
    }
    if (attachment.kind === "reference" && (
      !AI_INPUT_ASSET_KINDS.has(asset.kind)
      || !AI_REFERENCE_MIME_TYPES.has(asset.mimeType)
    )) {
      throw new ApiError(422, "INVALID_REFERENCE", "Chat references must be PNG, JPEG, or WebP reference images");
    }
    if (asset.stickerId && asset.stickerId !== stickerId) {
      throw new ApiError(422, "ASSET_STICKER_MISMATCH", "An attachment belongs to another sticker");
    }
  }
  const selectedTarget = baseDocument?.layers.find((layer) => layer.type === "image" && (
    request.targetLayerId ? layer.id === request.targetLayerId : true
  ));
  const selectedTargetAsset = request.intent === "edit" && request.imagePlacement !== "add" && selectedTarget?.type === "image"
    ? await getReadyOwnedAssets(db, ownerId, [selectedTarget.assetId]).then((items) => items[0])
    : undefined;
  const totalAiInputBytes = attachedAssets.reduce((total, asset) => total + (asset.byteSize ?? 0), 0)
    + (selectedTargetAsset?.byteSize ?? 0);
  if (totalAiInputBytes > MAX_AI_INPUT_BYTES) {
    throw new ApiError(422, "AI_INPUT_TOO_LARGE", "Combined AI image inputs must not exceed 32 MB");
  }
  const maskAttachments = request.attachments.filter((attachment) => attachment.kind === "mask");
  if (maskAttachments.length > 1) {
    throw new ApiError(422, "TOO_MANY_MASKS", "One edit may contain at most one mask");
  }
  if (maskAttachments.length === 1) {
    if (!baseRevision || !baseDocument) throw new ApiError(422, "MASK_TARGET_REQUIRED", "A mask requires an existing image layer");
    const document = baseDocument;
    const requestedLayerId = maskAttachments[0].targetLayerId ?? request.targetLayerId;
    const targetLayer = document.layers.find((layer) => layer.type === "image" && (!requestedLayerId || layer.id === requestedLayerId));
    if (!targetLayer || targetLayer.type !== "image") throw new ApiError(422, "MASK_TARGET_REQUIRED", "The target image layer does not exist");
    const targetAsset = await getReadyOwnedAssets(db, ownerId, [targetLayer.assetId]).then((items) => items[0]);
    const maskAsset = byId.get(maskAttachments[0].assetId)!;
    if (maskAsset.mimeType !== targetAsset.mimeType || maskAsset.width !== targetAsset.width || maskAsset.height !== targetAsset.height) {
      throw new ApiError(422, "MASK_DIMENSIONS_MISMATCH", "The mask and target image must have the same format and dimensions");
    }
  }
  if (request.intent === "animate" && sticker.kind !== "animated") {
    throw new ApiError(422, "STATIC_STICKER_CANNOT_ANIMATE", "This sticker was created in static mode");
  }

  const messageId = crypto.randomUUID();
  const jobId = crypto.randomUUID();
  const now = new Date();
  const jobKind = intentToJobKind(request.intent);
  const creditHold = jobCreditHold(jobKind);
  const policy = appClip ? await quickGenerationPolicy(ownerId) : null;
  let reservationId: string | null = null;
  try {
    reservationId = policy && !policy.chargesPoints ? null : await holdCreditsForJob({
      ownerId,
      amount: creditHold,
      idempotencyKey: `reserve:${jobId}`,
      description: `Sticker ${request.intent}`,
      metadata: { jobId, stickerId, kind: jobKind },
    });
    // Check points before consuming an attempt. The existing usage API records
    // immediately; generation failures keep the attempt but release point holds.
    if (appClip) await recordAppClipUsage(ownerId, jobId);
    // Every user message spends the daily message allowance; the one that opens a
    // new sticker spends the daily sticker allowance too.
    else await consumeDailyUsage(ownerId, newSticker
      ? [DAILY_STICKER_GENERATION_ITEM, DAILY_STICKER_REFINEMENT_ITEM]
      : [DAILY_STICKER_REFINEMENT_ITEM], jobId);
    await db.transaction(async (tx) => {
      if (request.planPoseUpdate) {
        // Serialize against manual edits and version restoration. The active-job constraint guards concurrent builds.
        await tx.select({ id: stickers.id }).from(stickers).where(eq(stickers.id, stickerId)).for("update");
        const current = await tx.select().from(plans).where(and(
          eq(plans.id, request.planPoseUpdate.planId), eq(plans.stickerId, stickerId), eq(plans.ownerId, ownerId),
        )).then(firstRow);
        const latest = await tx.select({ planId: chatMessages.planId }).from(chatMessages)
          .where(and(eq(chatMessages.threadId, thread.id), eq(chatMessages.kind, "plan"), eq(chatMessages.role, "assistant")))
          .orderBy(desc(chatMessages.sequence)).limit(1).then(firstRow);
        if (!current || current.state !== "finalized" || current.revision !== request.planPoseUpdate.currentRevision || latest?.planId !== current.id) {
          throw new ApiError(409, "PLAN_CHANGED", "The latest plan changed. Reload it before changing poses");
        }
        if (!current.planJson.layers.some((layer) => layer.source.kind === "sprite")) {
          throw new ApiError(422, "INVALID_POSE_PRESET", "This plan has no controllable characters");
        }
        if (request.planPoseUpdate.edit) {
          // Save the other layer-editor changes in this transaction, so the re-plan sees them.
          // A failure to queue rolls back both the manual edits and the selected preset.
          const saved = await editPlan(tx, ownerId, stickerId, current.id, request.planPoseUpdate.edit, current.revision);
          if (!saved.plan.plan.layers.some((layer) => layer.source.kind === "sprite")) {
            throw new ApiError(422, "INVALID_POSE_PRESET", "Keep a controllable character when changing pose variety");
          }
        }
      }
      const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
        .where(eq(chatMessages.threadId, thread.id)).then(firstRow);
      const sequence = (sequenceRow?.value ?? 0) + 1;
      try {
        await tx.insert(generationJobs).values({
          id: jobId,
          ownerId,
          stickerId,
          sourceMessageId: messageId,
          kind: jobKind,
          quick: request.quick ?? false,
          appClip,
          state: "queued",
          reservationId,
          billingEnvironment: await currentBillingEnvironment(),
          reservationAmount: reservationId ? creditHold : 0,
          createdAt: now,
          updatedAt: now,
        });
      } catch (error) {
        if (isActiveJobConstraint(error)) {
          throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
        }
        throw error;
      }
      await tx.insert(chatMessages).values({
        id: messageId,
        threadId: thread.id,
        ownerId,
        role: "user",
        kind: request.planPoseUpdate ? "plan" : request.intent === "animate"
          ? "animation"
          : request.intent === "edit"
            ? "image_edit"
            : request.intent === "generate"
              ? "image"
              : "text",
        content: request.text,
        targetLayerId: request.targetLayerId,
        baseRevisionId: baseRevision?.id,
        imagePlacement: request.imagePlacement,
        sequence,
        jobId,
        status: "streaming",
        createdAt: now,
      });
      if (request.attachments.length > 0) {
        await tx.insert(chatAttachments).values(request.attachments.map((attachment, position) => ({
          messageId,
          assetId: attachment.assetId,
          kind: attachment.kind,
          targetLayerId: attachment.targetLayerId ?? request.targetLayerId,
          position,
        })));
        const expectedClaims = attachedAssets.filter((asset) => asset.stickerId === null).length;
        const claimed = await tx.update(assets).set({ stickerId }).where(and(
          eq(assets.ownerId, ownerId),
          isNull(assets.stickerId),
          inArray(assets.id, assetIds),
        )).returning({ id: assets.id });
        if (claimed.length !== expectedClaims) {
          throw new ApiError(409, "ASSET_ALREADY_ATTACHED", "An attachment was concurrently claimed by another sticker");
        }
      }
      await tx.update(chatThreads).set({ updatedAt: now }).where(eq(chatThreads.id, thread.id));
      await tx.update(stickers).set({
        updatedAt: now,
        ...(request.planPoseUpdate ? { posePreset: request.planPoseUpdate.posePreset, controllable: true } : {}),
      }).where(eq(stickers.id, stickerId));
      await tx.insert(generationEvents).values({
        jobId,
        ownerId,
        type: "queued",
        dataJson: { intent: request.intent, messageId },
        createdAt: now,
      });
    });
  } catch (error) {
    await abandonHold(reservationId, jobId, "job_not_created");
    throw error;
  }
  return { sticker, messageId, jobId };
}

export async function retryFailedChatTurn(
  db: Database,
  ownerId: string,
  stickerId: string,
  sourceMessageId: string,
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const thread = await db.select().from(chatThreads).where(and(
    eq(chatThreads.stickerId, stickerId),
    eq(chatThreads.ownerId, ownerId),
  )).then(firstRow);
  if (!thread) throw new ApiError(404, "CHAT_NOT_FOUND", "Chat not found");
  const message = await db.select().from(chatMessages).where(and(
    eq(chatMessages.id, sourceMessageId),
    eq(chatMessages.threadId, thread.id),
    eq(chatMessages.ownerId, ownerId),
    eq(chatMessages.role, "user"),
  )).then(firstRow);
  if (!message || !message.jobId) throw new ApiError(404, "MESSAGE_NOT_FOUND", "Retry source message not found");
  if (message.status !== "failed") throw new ApiError(409, "MESSAGE_NOT_RETRYABLE", "Only the latest failed AI turn can be retried");
  const original = await db.select().from(generationJobs).where(and(
    eq(generationJobs.id, message.jobId),
    eq(generationJobs.ownerId, ownerId),
    eq(generationJobs.stickerId, stickerId),
  )).then(firstRow);
  if (!original || (original.state !== "failed" && original.state !== "cancelled")) {
    throw new ApiError(409, "JOB_NOT_RETRYABLE", "Only failed or cancelled AI turns can be retried");
  }
  const attempts = await db.select({ value: count() }).from(generationJobs)
    .where(and(eq(generationJobs.sourceMessageId, sourceMessageId), eq(generationJobs.ownerId, ownerId))).then(firstRow);
  if ((attempts?.value ?? 0) >= 4) throw new ApiError(429, "RETRY_LIMIT_REACHED", "This AI turn has reached its retry limit");
  const jobId = crypto.randomUUID();
  // A retry is a fresh attempt at the provider, so it gets the same estimated
  // hold. The original's own hold was released when it failed.
  const creditHold = jobCreditHold(original.kind);
  const reservationId = await holdCreditsForJob({
    ownerId,
    amount: creditHold,
    idempotencyKey: `reserve:${jobId}`,
    description: `Sticker ${original.kind} retry`,
    metadata: { jobId, stickerId, kind: original.kind, retryOfJobId: original.id },
  });
  try {
    await db.transaction(async (tx) => {
      const now = new Date();
      await tx.insert(generationJobs).values({
        id: jobId,
        ownerId,
        stickerId,
        sourceMessageId,
        kind: original.kind,
        // Carried rather than defaulted: a retry is another attempt at the same turn, and the
        // surface that asked for it has no chance to say so again — the extension's retry is the
        // same Retry button the app has.
        quick: original.quick,
        state: "queued",
        reservationId,
        billingEnvironment: await currentBillingEnvironment(),
        reservationAmount: reservationId ? creditHold : 0,
        createdAt: now,
        updatedAt: now,
      });
      await tx.insert(generationEvents).values({
        jobId,
        ownerId,
        type: "queued",
        dataJson: { retryOfJobId: original.id, sourceMessageId },
        createdAt: now,
      });
      const claimed = await tx.update(chatMessages).set({ jobId, status: "streaming" }).where(and(
        eq(chatMessages.id, sourceMessageId),
        eq(chatMessages.jobId, original.id),
        eq(chatMessages.status, "failed"),
      )).returning({ id: chatMessages.id });
      if (claimed.length !== 1) {
        throw new ApiError(409, "MESSAGE_NOT_RETRYABLE", "Another retry already claimed this failed AI turn");
      }
    });
  } catch (error) {
    await abandonHold(reservationId, jobId, "job_not_created");
    if (isActiveJobConstraint(error)) {
      throw new ApiError(409, "AI_TURN_IN_PROGRESS", "This sticker already has an active AI turn");
    }
    throw error;
  }
  return { messageId: sourceMessageId, jobId };
}

export async function listChatMessages(
  db: Database,
  ownerId: string,
  stickerId: string,
  options: { afterSequence?: number; beforeSequence?: number; limit?: number; latest?: boolean } = {},
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const thread = await db.select().from(chatThreads).where(eq(chatThreads.stickerId, stickerId)).then(firstRow);
  if (!thread || thread.ownerId !== ownerId) throw new ApiError(404, "CHAT_NOT_FOUND", "Chat not found");
  const limit = Math.min(options.limit ?? 100, 200);
  const newestFirst = options.beforeSequence !== undefined || Boolean(options.latest) || options.afterSequence === undefined;
  const rows = await db.select().from(chatMessages).where(and(
    eq(chatMessages.threadId, thread.id),
    options.afterSequence !== undefined ? gt(chatMessages.sequence, options.afterSequence) : undefined,
    options.beforeSequence !== undefined ? lt(chatMessages.sequence, options.beforeSequence) : undefined,
  )).orderBy(newestFirst ? desc(chatMessages.sequence) : asc(chatMessages.sequence)).limit(limit + 1);
  const hasOlder = newestFirst && rows.length > limit;
  const filtered = rows.slice(0, limit);
  if (newestFirst) filtered.reverse();
  const messageIds = filtered.map((row) => row.id);
  const attachments = messageIds.length
    ? await db.select().from(chatAttachments).where(inArray(chatAttachments.messageId, messageIds)).orderBy(asc(chatAttachments.position))
    : [];
  // Resolved through the message's own `planId` rather than by matching `plans.messageId`: one
  // plan is now shown many times, so the plan does not belong to a single message any more.
  const planRows = await loadPlansByIds(db, [...new Set(
    filtered.map((row) => row.planId).filter((id): id is string => id !== null),
  )]);
  // Tool details live in the durable event log, alongside the streamed status.
  const toolIds = filtered.filter((row) => row.role === "system" && row.kind === "status").map((row) => row.id);
  const toolJobIds = [...new Set(filtered.filter((row) => toolIds.includes(row.id)).flatMap((row) => row.jobId ? [row.jobId] : []))];
  const toolEvents = toolIds.length && toolJobIds.length
    ? await db.select({ data: generationEvents.dataJson }).from(generationEvents).where(and(
      eq(generationEvents.ownerId, ownerId),
      inArray(generationEvents.jobId, toolJobIds),
      inArray(sql<string>`${generationEvents.dataJson}->>'toolCallId'`, toolIds),
      sql`${generationEvents.dataJson}->>'toolDetails' IS NOT NULL`,
    )).orderBy(asc(generationEvents.id))
    : [];
  const toolDetails = new Map(toolEvents.map(({ data }) => [data.toolCallId, data.toolDetails]));
  return {
    data: filtered.map((message) => ({
      ...serializeChatMessage(
        message,
        attachments.filter((item) => item.messageId === message.id),
        planRows.find((plan) => plan.id === message.planId),
      ),
      toolDetails: toolDetails.get(message.id),
    })),
    nextBeforeSequence: hasOlder && filtered.length > 0 ? filtered[0].sequence : null,
  };
}

/**
 * The single client-facing shape for a chat message. Shared by the transcript endpoint and by
 * generation events, so a message delivered over the stream is byte-identical to the one a
 * refetch would return.
 */
export function serializeChatMessage(
  message: typeof chatMessages.$inferSelect,
  attachments: Array<typeof chatAttachments.$inferSelect> = [],
  plan?: typeof plans.$inferSelect,
) {
  return {
    // `planRevision` is what the card was rendering when it was posted, so a card from before the
    // agent revised the draft serializes as read-only rather than offering a stale Generate button.
    plan: plan ? serializePlan(plan, { atRevision: message.planRevision }) : undefined,
    id: message.id,
    role: message.role,
    kind: message.kind,
    content: message.content,
    targetLayerId: message.targetLayerId,
    baseRevisionId: message.baseRevisionId,
    imagePlacement: message.imagePlacement,
    sequence: message.sequence,
    revisionId: message.revisionId,
    jobId: message.jobId,
    status: message.status,
    createdAt: message.createdAt.toISOString(),
    attachments: attachments.map((item) => ({
      assetId: item.assetId,
      kind: item.kind,
      targetLayerId: item.targetLayerId,
    })),
  };
}
