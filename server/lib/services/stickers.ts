import { resolveCreationPresets, creationPresetDisplay } from "@/lib/creation-presets/selection";
import { currentBillingEnvironment } from "@/lib/subscription/client";
import { and, asc, desc, eq, gt, inArray, isNull, lt, lte } from "drizzle-orm";
import type { CreateStickerRequest, ImportStickerRequest, UpdateStickerRequest } from "@/lib/contracts/api";
import { CURRENT_DOCUMENT_VERSION, downcastForClient, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, chatMessages, chatThreads, generationEvents, generationJobs, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getReadyOwnedAssets } from "@/lib/services/assets";
import { abandonHold, holdCreditsForJob } from "@/lib/subscription/credits";
import { AI_INPUT_ASSET_KINDS, AI_REFERENCE_MIME_TYPES, MAX_AI_INPUT_BYTES, assertOwnedSticker, isActiveJobConstraint, serializeSticker } from "./sticker-summaries";

export async function createSticker(db: Database, ownerId: string, request: CreateStickerRequest) {
  const creationPresets = resolveCreationPresets(request.presets);
  if (creationPresets?.selections.some((group) => group.groupId === "style"
    && group.options.some((option) => option.id === "pet-companion"))
    && (request.kind !== "animated" || request.controllable !== true)) {
    throw new ApiError(422, "PET_STYLE_REQUIRES_CONTROLS", "Pet Companion needs an animated sticker with switchable moods and poses.");
  }
  const references = await getReadyOwnedAssets(db, ownerId, request.referenceAssetIds);
  if (references.some((asset) => !AI_INPUT_ASSET_KINDS.has(asset.kind))) {
    throw new ApiError(422, "INVALID_REFERENCE", "Initial references must be reference image assets");
  }
  if (references.some((asset) => !AI_REFERENCE_MIME_TYPES.has(asset.mimeType))) {
    throw new ApiError(422, "INVALID_REFERENCE", "Initial references must be PNG, JPEG, or WebP images");
  }
  if (references.reduce((total, asset) => total + (asset.byteSize ?? 0), 0) > MAX_AI_INPUT_BYTES) {
    throw new ApiError(422, "AI_INPUT_TOO_LARGE", "Combined AI image inputs must not exceed 32 MB");
  }
  if (references.some((asset) => asset.stickerId !== null)) {
    throw new ApiError(422, "REFERENCE_ALREADY_ATTACHED", "An initial reference is already attached to another sticker");
  }
  const stickerId = crypto.randomUUID();
  const threadId = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.insert(stickers).values({
      id: stickerId,
      ownerId,
      title: request.title,
      kind: request.kind,
      creationPresets,
      controllable: request.controllable,
      posePreset: request.posePreset,
      // Absent means still: the column's own default carries the same answer, so an older client
      // that never sends the field gets a sticker that holds its place.
      motion: request.motion ?? false,
      status: "draft",
      createdAt: now,
      updatedAt: now,
    });
    await tx.insert(chatThreads).values({ id: threadId, stickerId, ownerId, createdAt: now, updatedAt: now });
    if (request.referenceAssetIds.length > 0) {
      const claimed = await tx.update(assets).set({ stickerId }).where(and(
        eq(assets.ownerId, ownerId),
        isNull(assets.stickerId),
        inArray(assets.id, request.referenceAssetIds),
      )).returning({ id: assets.id });
      if (claimed.length !== request.referenceAssetIds.length) {
        throw new ApiError(409, "REFERENCE_ALREADY_ATTACHED", "An initial reference was concurrently attached to another sticker");
      }
    }
  });
  return { stickerId, threadId };
}

/**
 * Turns an image the user already has into a static sticker project, with no generation.
 *
 * The whole point is that nothing is drawn: the asset carries the pixels, so this writes the
 * sticker, its thread, and a root revision that is accepted and active from the moment it exists.
 * Accepted-on-arrival mirrors `saveEditedRevision` and for the same reason — the user has already
 * seen this picture and chosen it, so a review gate would only ask them to confirm their own
 * choice. Being active is also what lets the client publish exports for it straight away, which is
 * what actually puts the sticker in the Messages pack.
 *
 * There is no generation job — nothing was asked of the model — but there is one transcript entry,
 * so the project opens on the sticker rather than on an empty room. See the insert below for why it
 * is a `device_edit` marker and not a user turn.
 */
export async function importSticker(db: Database, ownerId: string, request: ImportStickerRequest) {
  const [asset] = await getReadyOwnedAssets(db, ownerId, [request.assetId]);
  // Narrower than `AI_INPUT_ASSET_KINDS`, which admits `sequence`: a frame atlas is a PNG contact
  // sheet, so it would pass every check here and then be refused at publish time as an image layer
  // — after the project already existed. This is the same set `validateDocumentAssetReferences`
  // accepts for an image layer, minus the rendition kinds an import can never be holding.
  if (asset.kind !== "reference" && asset.kind !== "chat_attachment") {
    throw new ApiError(422, "INVALID_REFERENCE", "An imported sticker must be built from a reference image asset");
  }
  if (!AI_REFERENCE_MIME_TYPES.has(asset.mimeType)) {
    throw new ApiError(422, "INVALID_REFERENCE", "An imported sticker must be a PNG, JPEG, or WebP image");
  }
  if (asset.stickerId !== null) {
    throw new ApiError(422, "REFERENCE_ALREADY_ATTACHED", "That image is already attached to another sticker");
  }

  const stickerId = crypto.randomUUID();
  const threadId = crypto.randomUUID();
  const revisionId = crypto.randomUUID();
  const messageId = crypto.randomUUID();
  const now = new Date();
  const document = StickerDocumentSchema.parse({
    version: CURRENT_DOCUMENT_VERSION,
    kind: "static",
    canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
    mp4Background: { type: "solid", color: "#FFFFFF" },
    durationSeconds: 0,
    fps: 0,
    loop: "once",
    layers: [{
      id: "hero",
      name: "Hero",
      hidden: false,
      type: "image",
      assetId: request.assetId,
      contentMode: "fit",
      animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [] },
    }],
  });

  await db.transaction(async (tx) => {
    await tx.insert(stickers).values({
      id: stickerId,
      ownerId,
      title: request.title,
      kind: "static",
      status: "draft",
      createdAt: now,
      updatedAt: now,
    });
    await tx.insert(chatThreads).values({ id: threadId, stickerId, ownerId, createdAt: now, updatedAt: now });
    // Claiming the asset is conditional on it still being unattached, so two imports racing on the
    // same upload cannot both end up with a document pointing at artwork the other one owns.
    const claimed = await tx.update(assets).set({ stickerId }).where(and(
      eq(assets.ownerId, ownerId),
      isNull(assets.stickerId),
      eq(assets.id, request.assetId),
    )).returning({ id: assets.id });
    if (claimed.length !== 1) {
      throw new ApiError(409, "REFERENCE_ALREADY_ATTACHED", "That image was concurrently attached to another sticker");
    }
    // The project opens on something rather than on nothing. An imported sticker has no turn behind
    // it, so without this its transcript is blank — the user taps into the sticker they just made
    // and is shown an empty room. Posted as `device_edit` for the same reason `saveEditedRevision`
    // does: the user never said this, and a bubble quoting words they did not type is a message the
    // agent would answer on the next turn. The app draws the kind as a divider with the artwork
    // under it, which is exactly what happened here.
    await tx.insert(chatMessages).values({
      id: messageId,
      threadId,
      ownerId,
      role: "user",
      kind: "device_edit",
      content: "Added to your stickers",
      sequence: 1,
      revisionId,
      status: "complete",
      createdAt: now,
    });
    await tx.insert(stickerRevisions).values({
      id: revisionId,
      stickerId,
      parentRevisionId: null,
      sourceMessageId: messageId,
      kind: "static",
      candidateState: "accepted",
      documentJson: document,
      createdAt: now,
      decidedAt: now,
    });
    await tx.update(stickers).set({ activeRevisionId: revisionId, updatedAt: now }).where(eq(stickers.id, stickerId));
  });

  return { stickerId, threadId, revisionId };
}

export async function updateSticker(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: UpdateStickerRequest,
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  await db.update(stickers).set({
    title: request.title,
    updatedAt: new Date(),
  }).where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId)));
  return getSticker(db, ownerId, stickerId);
}

export async function createExportJob(
  db: Database,
  ownerId: string,
  stickerId: string,
  creditCost = 0,
) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const id = crypto.randomUUID();
  const reservationId = await holdCreditsForJob({
    ownerId,
    amount: creditCost,
    idempotencyKey: `reserve:${id}`,
    description: "Sticker export",
    metadata: { jobId: id, stickerId, kind: "export" },
  });
  try {
    await db.transaction(async (tx) => {
      const now = new Date();
      await tx.insert(generationJobs).values({
        id,
        ownerId,
        stickerId,
        kind: "export",
        state: "queued",
        reservationId,
        billingEnvironment: await currentBillingEnvironment(),
        reservationAmount: reservationId ? creditCost : 0,
        createdAt: now,
        updatedAt: now,
      });
      await tx.insert(generationEvents).values({ jobId: id, ownerId, type: "queued", dataJson: { kind: "export" }, createdAt: now });
    });
  } catch (error) {
    await abandonHold(reservationId, id, "job_not_created");
    if (isActiveJobConstraint(error)) {
      throw new ApiError(409, "AI_TURN_IN_PROGRESS", "Wait for the current sticker operation to finish");
    }
    throw error;
  }
  return id;
}

export async function createCleanupJob(db: Database, ownerId: string, stickerId: string) {
  const sticker = await db.select().from(stickers).where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId))).then(firstRow);
  if (!sticker) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  if (sticker.status === "deleting") return retryFailedCleanupJob(db, ownerId, stickerId);
  if (sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  const active = await db.select({ id: generationJobs.id }).from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    inArray(generationJobs.state, ["queued", "running", "waiting"]),
  )).then(firstRow);
  if (active) throw new ApiError(409, "STICKER_OPERATION_IN_PROGRESS", "Wait for the current sticker operation before deleting this project");
  // No credit hold. Deleting your own work is never billed — charging for it
  // would let a user run out of credits with no way to free their storage.
  const id = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.update(stickers).set({ status: "deleting", deletedAt: now, updatedAt: now }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
    ));
    await tx.insert(generationJobs).values({
      id,
      ownerId,
      stickerId,
      kind: "cleanup",
      priorStickerStatus: sticker.status === "published" ? "published" : "draft",
      state: "queued",
      createdAt: now,
      updatedAt: now,
    });
    await tx.insert(generationEvents).values({ jobId: id, ownerId, type: "queued", dataJson: { kind: "cleanup" }, createdAt: now });
  });
  return id;
}

export async function retryFailedCleanupJob(db: Database, ownerId: string, stickerId: string): Promise<string> {
  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
    eq(stickers.status, "deleting"),
  )).then(firstRow);
  if (!sticker) throw new ApiError(404, "STICKER_NOT_FOUND", "Deleting sticker not found");
  const job = await db.select().from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    eq(generationJobs.ownerId, ownerId),
    eq(generationJobs.kind, "cleanup"),
    eq(generationJobs.state, "failed"),
    gt(generationJobs.attempts, 0),
  )).orderBy(desc(generationJobs.updatedAt)).then(firstRow);
  if (!job) throw new ApiError(409, "CLEANUP_NOT_RETRYABLE", "The cleanup is not in a retryable failed state");
  if (job.attempts >= 5) throw new ApiError(409, "CLEANUP_RETRY_LIMIT", "Cleanup requires operator reconciliation after five attempts");
  const now = new Date();
  await db.transaction(async (tx) => {
    const changed = await tx.update(generationJobs).set({
      state: "queued",
      errorCode: null,
      errorMessage: null,
      completedAt: null,
      updatedAt: now,
    }).where(and(
      eq(generationJobs.id, job.id),
      eq(generationJobs.state, "failed"),
      eq(generationJobs.attempts, job.attempts),
    )).returning({ id: generationJobs.id });
    if (changed.length !== 1) throw new ApiError(409, "CLEANUP_RETRY_CLAIMED", "Another cleanup retry already started");
    await tx.insert(generationEvents).values({
      jobId: job.id,
      ownerId,
      type: "queued",
      dataJson: { kind: "cleanup", retryAttempt: job.attempts + 1 },
      createdAt: now,
    });
  });
  return job.id;
}

export async function requeueFailedCleanupJobs(
  db: Database,
  options: { limit?: number; olderThan?: Date } = {},
): Promise<Array<{ jobId: string; ownerId: string }>> {
  const limit = Math.min(Math.max(options.limit ?? 20, 1), 50);
  const olderThan = options.olderThan ?? new Date(Date.now() - 5 * 60 * 1000);
  const candidates = await db.select().from(generationJobs).where(and(
    eq(generationJobs.kind, "cleanup"),
    eq(generationJobs.state, "failed"),
    gt(generationJobs.attempts, 0),
    lt(generationJobs.attempts, 5),
    lte(generationJobs.updatedAt, olderThan),
  )).orderBy(asc(generationJobs.updatedAt)).limit(limit);
  const claimed: Array<{ jobId: string; ownerId: string }> = [];
  for (const candidate of candidates) {
    try {
      const jobId = await retryFailedCleanupJob(db, candidate.ownerId, candidate.stickerId);
      claimed.push({ jobId, ownerId: candidate.ownerId });
    } catch (error) {
      if (!(error instanceof ApiError) || error.status >= 500) throw error;
    }
  }
  return claimed;
}

/**
 * Degrades every revision's document to what `clientVersion` can decode.
 *
 * Applied at the route rather than inside `getSticker` so the service keeps returning a real
 * `StickerDocument` — the web library renders the same payload in-process and has no old-client
 * problem, and typing it as "some version of a document" would infect every caller for the benefit
 * of one. The API route is the only place that has a client to ask about.
 */
export function downcastStickerDetail<
  T extends { revisions: Array<{ document: StickerDocument }> },
>(detail: T, clientVersion: number): unknown {
  if (clientVersion >= CURRENT_DOCUMENT_VERSION) return detail;
  return {
    ...detail,
    revisions: detail.revisions.map((revision) => ({
      ...revision,
      document: downcastForClient(revision.document, clientVersion),
    })),
  };
}

export async function getSticker(db: Database, ownerId: string, stickerId: string) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const revisions = await db.select().from(stickerRevisions)
    .where(eq(stickerRevisions.stickerId, stickerId)).orderBy(desc(stickerRevisions.createdAt));
  return {
    ...(await serializeSticker(db, sticker)),
    presets: creationPresetDisplay(sticker.creationPresets),
    revisions: revisions.map((revision) => ({
      id: revision.id,
      parentRevisionId: revision.parentRevisionId,
      sourceMessageId: revision.sourceMessageId,
      candidateState: revision.candidateState,
      document: StickerDocumentSchema.parse(revision.documentJson),
      masterAssetId: revision.masterAssetId,
      previewAssetId: revision.previewAssetId,
      pngAssetId: revision.pngAssetId,
      apngAssetId: revision.apngAssetId,
      // Still served: a revision published before the switch carries its sharing rendition here and
      // nowhere else, and the clients resolve whichever of the two is set.
      gifAssetId: revision.gifAssetId,
      mp4AssetId: revision.mp4AssetId,
      systemAssetId: revision.systemAssetId,
      attachmentMediumAssetId: revision.attachmentMediumAssetId,
      attachmentSmallAssetId: revision.attachmentSmallAssetId,
      webpAssetId: revision.webpAssetId,
      createdAt: revision.createdAt.toISOString(),
      decidedAt: revision.decidedAt?.toISOString() ?? null,
    })),
  };
}

// The rest of the sticker service. Re-exported so every existing
// `@/lib/services/stickers` import keeps working.
export { assertOwnedSticker, attachmentMediumSummaryColumns, attachmentSmallSummaryColumns, buildStickerListQuery, isActiveJobConstraint, listStickers, previewAssetSummaryColumns, selectStickerSummaries, serializeStickerListRows, serializeStickerSummary, stickerSummaryColumns, systemAssetSummaryColumns, telegramSummaryColumns, webpSummaryColumns, whatsappSummaryColumns } from "./sticker-summaries";
export type { AssetSummary, ListStickersOptions, StickerCursor, StickerSummaryRow } from "./sticker-summaries";
export { assertValidAnimationBase, expectedRenditionDuration, isValidAnimationBase, validateAnimatedRenditionTiming, validateDocumentAssetReferences } from "./sticker-documents";
export { createChatTurn, listChatMessages, retryFailedChatTurn, serializeChatMessage } from "./sticker-chat";
export { acceptRevision, createCandidateRevision, rejectRevision, revertRevision, saveEditedRevision } from "./sticker-revisions";
export { bindExports, bindMessengerRenditions } from "./sticker-exports";
