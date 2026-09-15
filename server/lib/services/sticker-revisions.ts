// The revision lifecycle - candidate, accept, reject, revert - and the device-side edit that
// saves a new revision directly.

import { and, eq, inArray, max, ne } from "drizzle-orm";
import type { SaveEditedDocumentRequest } from "@/lib/contracts/api";
import { StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, chatThreads, generationJobs, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { ensureSequencePosters } from "@/lib/services/assets";
import { revisionHasPublishedExports, validateDocumentAssetReferences } from "./sticker-documents";
import { assertOwnedSticker } from "./sticker-summaries";

export async function acceptRevision(db: Database, ownerId: string, stickerId: string, revisionId: string) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (!revision) throw new ApiError(404, "REVISION_NOT_FOUND", "Revision not found");
  if (revision.candidateState === "accepted" && sticker.activeRevisionId === revisionId) {
    return { revisionId, candidateState: "accepted" as const, activeRevisionId: revisionId };
  }
  if (revision.candidateState !== "candidate") throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is no longer a candidate");
  const now = new Date();
  await db.transaction(async (tx) => {
    const changed = await tx.update(stickerRevisions).set({ candidateState: "accepted", decidedAt: now }).where(and(
      eq(stickerRevisions.id, revisionId),
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
    )).returning({ id: stickerRevisions.id });
    if (changed.length === 0) throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is no longer a candidate");
    await tx.update(stickerRevisions).set({ candidateState: "superseded", decidedAt: now }).where(and(
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
      ne(stickerRevisions.id, revisionId),
    ));
    await tx.update(stickers).set({
      activeRevisionId: revisionId,
      status: revisionHasPublishedExports(revision) ? "published" : "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });
  return { revisionId, candidateState: "accepted" as const, activeRevisionId: revisionId };
}

export async function rejectRevision(db: Database, ownerId: string, stickerId: string, revisionId: string) {
  await assertOwnedSticker(db, ownerId, stickerId);
  const existing = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (existing?.candidateState === "rejected") return { revisionId, candidateState: "rejected" as const };
  const [revision] = await db.update(stickerRevisions).set({ candidateState: "rejected", decidedAt: new Date() })
    .where(and(
      eq(stickerRevisions.id, revisionId),
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
    )).returning();
  if (!revision) throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is missing or no longer a candidate");
  return { revisionId, candidateState: "rejected" as const };
}

export async function revertRevision(db: Database, ownerId: string, stickerId: string, revisionId: string, decisionId = crypto.randomUUID()) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const priorResult = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, decisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (priorResult) {
    return { revisionId: priorResult.id, revertedFromRevisionId: revisionId, activeRevisionId: priorResult.id };
  }
  const target = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (!target) throw new ApiError(404, "REVISION_NOT_FOUND", "Revision not found");
  const newRevisionId = decisionId;
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.insert(stickerRevisions).values({
      id: newRevisionId,
      stickerId,
      parentRevisionId: sticker.activeRevisionId,
      kind: target.kind,
      candidateState: "accepted",
      documentJson: StickerDocumentSchema.parse(target.documentJson),
      masterAssetId: target.masterAssetId,
      previewAssetId: target.previewAssetId,
      playbackJson: target.playbackJson,
      pngAssetId: target.pngAssetId,
      apngAssetId: target.apngAssetId,
      // Reverting to a revision published before the switch has to carry its GIF across, or the
      // restored revision comes back with no sharing rendition at all.
      gifAssetId: target.gifAssetId,
      mp4AssetId: target.mp4AssetId,
      systemAssetId: target.systemAssetId,
      createdAt: now,
      decidedAt: now,
    });
    await tx.update(stickers).set({
      activeRevisionId: newRevisionId,
      status: revisionHasPublishedExports(target) ? "published" : "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });
  return { revisionId: newRevisionId, revertedFromRevisionId: revisionId, activeRevisionId: newRevisionId };
}

export async function createCandidateRevision(
  db: Database,
  input: {
    ownerId: string;
    stickerId: string;
    sourceMessageId: string;
    document: StickerDocument;
    id?: string;
    parentRevisionId?: string;
    masterAssetId?: string;
    previewAssetId?: string;
  },
) {
  const sticker = await assertOwnedSticker(db, input.ownerId, input.stickerId);
  const id = input.id ?? crypto.randomUUID();
  // Derived before the document is stored, so the stored row already names a poster for every
  // capture. Doing it on read instead would mean an old client's fallback depended on a write
  // happening during a GET.
  const parsed = await ensureSequencePosters(
    db,
    input.ownerId,
    input.stickerId,
    StickerDocumentSchema.parse(input.document),
  );
  if (parsed.kind !== sticker.kind) {
    throw new ApiError(422, "REVISION_KIND_MISMATCH", "Revision document kind must match the sticker project kind");
  }
  if (input.id) {
    const existing = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, input.id)).then(firstRow);
    if (existing) {
      if (existing.stickerId !== input.stickerId || existing.sourceMessageId !== input.sourceMessageId) {
        throw new ApiError(409, "REVISION_ID_CONFLICT", "The deterministic revision ID belongs to another result");
      }
      return existing.id;
    }
  }
  if (input.parentRevisionId) {
    const parent = await db.select({ id: stickerRevisions.id }).from(stickerRevisions).where(and(
      eq(stickerRevisions.id, input.parentRevisionId),
      eq(stickerRevisions.stickerId, input.stickerId),
    )).then(firstRow);
    if (!parent) throw new ApiError(422, "INVALID_PARENT_REVISION", "The revision parent does not belong to this sticker");

  }
  const assetIds = [input.masterAssetId, input.previewAssetId].filter((value): value is string => Boolean(value));
  const revisionAssets = await validateDocumentAssetReferences(db, input.ownerId, input.stickerId, parsed, assetIds);
  if (input.masterAssetId && revisionAssets.get(input.masterAssetId)?.kind !== "master") {
    throw new ApiError(422, "INVALID_MASTER_ASSET", "The revision master must reference a ready master asset");
  }
  await db.insert(stickerRevisions).values({
    id,
    stickerId: input.stickerId,
    parentRevisionId: input.parentRevisionId ?? sticker.activeRevisionId,
    sourceMessageId: input.sourceMessageId,
    kind: parsed.kind,
    candidateState: "candidate",
    documentJson: parsed,
    masterAssetId: input.masterAssetId,
    previewAssetId: input.previewAssetId,
    createdAt: new Date(),
  });
  return id;
}

/**
 * Saves a document edited on the client as a new, already-accepted revision.
 *
 * Modelled on `revertRevision` rather than `createCandidateRevision`: both insert a revision that
 * is decided the moment it exists, keyed on a deterministic id so a retry is a no-op. The
 * difference from a generated candidate is that there is nothing to review — the user already saw
 * exactly what they made — so there is no candidate gate to pass through.
 *
 * The immutability trigger is never fought: this only inserts, and the only columns it later
 * updates are `candidate_state`/`decided_at`, which the trigger does not guard.
 */
export async function saveEditedRevision(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: SaveEditedDocumentRequest,
  revisionId = crypto.randomUUID(),
  clientVersion = 5,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);

  // Deterministic-id replay. Callers pass `idempotencyUuid(...)`, so a save retried after a flaky
  // connection returns the revision it already made instead of forking the chain.
  const prior = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (prior) {
    return {
      revisionId: prior.id,
      parentRevisionId: prior.parentRevisionId,
      candidateState: prior.candidateState,
      createdAt: prior.createdAt.toISOString(),
      stickerStatus: sticker.status,
    };
  }

  // Nothing in the schema serialises an edit against a running generation — the one-active-job
  // index guards jobs, not revisions. Without this, an edit saved mid-generation is superseded by
  // whatever the workflow lands moments later, with no sign that it happened.
  const activeJob = await db.select({ id: generationJobs.id }).from(generationJobs).where(and(
    eq(generationJobs.stickerId, stickerId),
    inArray(generationJobs.state, ["queued", "running", "waiting"]),
  )).then(firstRow);
  if (activeJob) {
    throw new ApiError(409, "STICKER_OPERATION_IN_PROGRESS", "Wait for the current sticker operation before saving an edit");
  }

  // A device-authored document arrives with no poster — the editor has no reason to derive one —
  // so this is the other place a capture's fallback still gets made.
  const document = await ensureSequencePosters(db, ownerId, stickerId, StickerDocumentSchema.parse(request.document));
  if (document.kind !== sticker.kind) {
    throw new ApiError(422, "REVISION_KIND_MISMATCH", "Revision document kind must match the sticker project kind");
  }

  const parent = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.parentRevisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (!parent) throw new ApiError(422, "INVALID_PARENT_REVISION", "The revision parent does not belong to this sticker");
  if (parent.documentJson.configuration && clientVersion < 5) throw new ApiError(409, "STICKER_CLIENT_UPDATE_REQUIRED", "Update the app before editing this configurable sticker");
  // Editing forward from a branch that was already turned down would resurrect it silently.
  if (parent.candidateState === "rejected" || parent.candidateState === "superseded") {
    throw new ApiError(409, "INVALID_PARENT_REVISION", "That revision was already rejected or superseded");
  }

  await validateDocumentAssetReferences(db, ownerId, stickerId, document);

  const now = new Date();
  await db.transaction(async (tx) => {
    // The edit shows up in the transcript so no revision is orphaned from the history, but it is
    // posted as `device_edit` rather than as an ordinary turn: the user never said this, and a
    // bubble quoting words they did not type reads as a message the agent should answer. The app
    // draws the kind as a divider instead.
    const thread = await tx.select().from(chatThreads).where(eq(chatThreads.stickerId, stickerId)).then(firstRow);
    let sourceMessageId: string | undefined;
    if (thread) {
      const sequenceRow = await tx.select({ value: max(chatMessages.sequence) }).from(chatMessages)
        .where(eq(chatMessages.threadId, thread.id)).then(firstRow);
      sourceMessageId = crypto.randomUUID();
      await tx.insert(chatMessages).values({
        id: sourceMessageId,
        threadId: thread.id,
        ownerId,
        role: "user",
        kind: "device_edit",
        // Still the message's own text rather than something the client composes: it is what the
        // agent reads in the transcript on the next turn, and what the divider is labelled with.
        content: request.note?.trim() || "Edited on device",
        baseRevisionId: request.parentRevisionId,
        sequence: (sequenceRow?.value ?? 0) + 1,
        revisionId,
        status: "complete",
        createdAt: now,
      });
    }

    await tx.insert(stickerRevisions).values({
      id: revisionId,
      stickerId,
      parentRevisionId: request.parentRevisionId,
      sourceMessageId,
      kind: document.kind,
      // Accepted on arrival: the user already saw what they made, so a review gate would only ask
      // them to confirm their own edit.
      candidateState: "accepted",
      documentJson: document,
      createdAt: now,
      decidedAt: now,
    });

    // Mirrors `acceptRevision`: promoting one revision retires any candidate still waiting, or the
    // chat would keep offering to accept something the edit has already moved past.
    await tx.update(stickerRevisions).set({ candidateState: "superseded", decidedAt: now }).where(and(
      eq(stickerRevisions.stickerId, stickerId),
      eq(stickerRevisions.candidateState, "candidate"),
      ne(stickerRevisions.id, revisionId),
    ));

    // An edited revision carries no renditions, so a previously published sticker drops back to
    // draft. That is correct — the published pixels no longer match the document — but it is
    // user-visible, which is why the app warns before saving over a published sticker.
    await tx.update(stickers).set({
      activeRevisionId: revisionId,
      status: "draft",
      updatedAt: now,
    }).where(eq(stickers.id, stickerId));
  });

  return {
    revisionId,
    parentRevisionId: request.parentRevisionId,
    candidateState: "accepted" as const,
    createdAt: now.toISOString(),
    stickerStatus: "draft" as const,
  };
}
