import { quickGenerationPolicy, recordAppClipUsage } from "@/lib/subscription/app-clip";
import { and, asc, count, desc, eq, gt, inArray, isNull, lt, lte, max, ne, or, sql } from "drizzle-orm";
import type {
  CreateStickerRequest,
  ImportStickerRequest,
  MessengerRenditionsRequest,
  PostChatMessageRequest,
  PublishExportsRequest,
  SaveEditedDocumentRequest,
  UpdateStickerRequest,
} from "@/lib/contracts/api";
import { ATTACHMENT_RENDITION_DIMENSIONS } from "@/lib/contracts/api";
import { countKeyframes } from "@/lib/animation/compile";
import {
  CURRENT_DOCUMENT_VERSION,
  downcastForClient,
  EXPORT_LOOP_HOLD_SECONDS,
  layerImageAssetIds,
  layerVideoAssetIds,
  StickerDocumentSchema,
  type StickerDocument,
} from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import {
  attachmentMediumAssets,
  attachmentSmallAssets,
  previewAssetIdSql,
  previewAssets,
  telegramAssets,
  webpAssets,
  whatsappAssets,
  systemAssets,
} from "@/lib/db/columns";
import {
  assets,
  chatAttachments,
  chatMessages,
  chatThreads,
  generationEvents,
  generationJobs,
  plans,
  stickerRevisions,
  stickers,
} from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { ensureSequencePosters, getReadyOwnedAssets } from "@/lib/services/assets";
import { loadPlansByIds, serializePlan } from "@/lib/services/plans";
import { abandonHold, holdCreditsForJob } from "@/lib/subscription/credits";
import { jobCreditHold } from "@/lib/subscription/pricing";

const MAX_AI_INPUT_BYTES = 32 * 1024 * 1024;
const AI_REFERENCE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/webp"]);

/**
 * The asset kinds a user may attach to a turn as visual input.
 *
 * `sequence` belongs here for a reason worth stating: a frame atlas is a PNG contact sheet, so it
 * reaches the model as an ordinary image and the model can *read the motion off it* the way a
 * person reads a storyboard. That is the property the whole sprite-sheet transport was chosen for,
 * and it is why no other part of the AI path — bounds checks, MIME allowlists, reference loading —
 * needed widening to support captured footage.
 */
const AI_INPUT_ASSET_KINDS = new Set(["reference", "chat_attachment", "sequence"]);

export interface StickerCursor {
  updatedAt: string;
  id: string;
}

/**
 * Recognises the `generation_jobs_one_active_per_sticker` partial unique index firing, including
 * when the driver has wrapped it, so callers can turn it into a 409 rather than a 500.
 */
export function isActiveJobConstraint(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; current && depth < 5; depth += 1) {
    const message = current instanceof Error ? current.message : String(current);
    if (message.includes("generation_jobs_one_active_per_sticker")) return true;
    current = typeof current === "object" && "cause" in current ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

function encodeCursor(cursor: StickerCursor): string {
  return Buffer.from(JSON.stringify(cursor)).toString("base64url");
}

function decodeCursor(cursor?: string | null): StickerCursor | undefined {
  if (!cursor) return undefined;
  try {
    const value = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as StickerCursor;
    if (!value.updatedAt || !value.id) throw new Error();
    return value;
  } catch {
    throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is invalid");
  }
}

export async function assertOwnedSticker(db: Database, ownerId: string, stickerId: string) {
  const sticker = await db.select().from(stickers).where(and(
    eq(stickers.id, stickerId),
    eq(stickers.ownerId, ownerId),
  )).then(firstRow);
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  return sticker;
}

export const stickerSummaryColumns = {
  id: stickers.id,
  title: stickers.title,
  kind: stickers.kind,
  status: stickers.status,
  activeRevisionId: stickers.activeRevisionId,
  messengerEmoji: stickers.messengerEmoji,
  createdAt: stickers.createdAt,
  updatedAt: stickers.updatedAt,
};

export const systemAssetSummaryColumns = {
  id: systemAssets.id,
  mimeType: systemAssets.mimeType,
  byteSize: systemAssets.byteSize,
  sha256: systemAssets.sha256,
};

/**
 * The `AssetV1` column set, once per aliased join.
 *
 * Spelled out three times rather than built by a helper, and deliberately: drizzle reads a
 * selection's nullability from the object literal itself, and routing these through a generic
 * function makes a left-joined group infer as fourteen independently nullable fields instead of one
 * nullable group — which typechecks at the call site and lies about the shape.
 */
export const previewAssetSummaryColumns = {
  id: previewAssets.id,
  stickerId: previewAssets.stickerId,
  kind: previewAssets.kind,
  state: previewAssets.state,
  mimeType: previewAssets.mimeType,
  byteSize: previewAssets.byteSize,
  width: previewAssets.width,
  height: previewAssets.height,
  frameCount: previewAssets.frameCount,
  durationSeconds: previewAssets.durationSeconds,
  fps: previewAssets.fps,
  sha256: previewAssets.sha256,
  hasAlpha: previewAssets.hasAlpha,
  createdAt: previewAssets.createdAt,
};

export const attachmentMediumSummaryColumns = {
  id: attachmentMediumAssets.id,
  stickerId: attachmentMediumAssets.stickerId,
  kind: attachmentMediumAssets.kind,
  state: attachmentMediumAssets.state,
  mimeType: attachmentMediumAssets.mimeType,
  byteSize: attachmentMediumAssets.byteSize,
  width: attachmentMediumAssets.width,
  height: attachmentMediumAssets.height,
  frameCount: attachmentMediumAssets.frameCount,
  durationSeconds: attachmentMediumAssets.durationSeconds,
  fps: attachmentMediumAssets.fps,
  sha256: attachmentMediumAssets.sha256,
  hasAlpha: attachmentMediumAssets.hasAlpha,
  createdAt: attachmentMediumAssets.createdAt,
};

export const attachmentSmallSummaryColumns = {
  id: attachmentSmallAssets.id,
  stickerId: attachmentSmallAssets.stickerId,
  kind: attachmentSmallAssets.kind,
  state: attachmentSmallAssets.state,
  mimeType: attachmentSmallAssets.mimeType,
  byteSize: attachmentSmallAssets.byteSize,
  width: attachmentSmallAssets.width,
  height: attachmentSmallAssets.height,
  frameCount: attachmentSmallAssets.frameCount,
  durationSeconds: attachmentSmallAssets.durationSeconds,
  fps: attachmentSmallAssets.fps,
  sha256: attachmentSmallAssets.sha256,
  hasAlpha: attachmentSmallAssets.hasAlpha,
  createdAt: attachmentSmallAssets.createdAt,
};

export const webpSummaryColumns = {
  id: webpAssets.id,
  stickerId: webpAssets.stickerId,
  kind: webpAssets.kind,
  state: webpAssets.state,
  mimeType: webpAssets.mimeType,
  byteSize: webpAssets.byteSize,
  width: webpAssets.width,
  height: webpAssets.height,
  frameCount: webpAssets.frameCount,
  durationSeconds: webpAssets.durationSeconds,
  fps: webpAssets.fps,
  sha256: webpAssets.sha256,
  hasAlpha: webpAssets.hasAlpha,
  createdAt: webpAssets.createdAt,
};

export const whatsappSummaryColumns = {
  id: whatsappAssets.id,
  stickerId: whatsappAssets.stickerId,
  kind: whatsappAssets.kind,
  state: whatsappAssets.state,
  mimeType: whatsappAssets.mimeType,
  byteSize: whatsappAssets.byteSize,
  width: whatsappAssets.width,
  height: whatsappAssets.height,
  frameCount: whatsappAssets.frameCount,
  durationSeconds: whatsappAssets.durationSeconds,
  fps: whatsappAssets.fps,
  sha256: whatsappAssets.sha256,
  hasAlpha: whatsappAssets.hasAlpha,
  createdAt: whatsappAssets.createdAt,
};

export const telegramSummaryColumns = {
  id: telegramAssets.id,
  stickerId: telegramAssets.stickerId,
  kind: telegramAssets.kind,
  state: telegramAssets.state,
  mimeType: telegramAssets.mimeType,
  byteSize: telegramAssets.byteSize,
  width: telegramAssets.width,
  height: telegramAssets.height,
  frameCount: telegramAssets.frameCount,
  durationSeconds: telegramAssets.durationSeconds,
  fps: telegramAssets.fps,
  sha256: telegramAssets.sha256,
  hasAlpha: telegramAssets.hasAlpha,
  createdAt: telegramAssets.createdAt,
};

/**
 * A sticker plus its active revision's system and preview assets, resolved in one statement.
 *
 * The database lives in a single region, so every extra `select` costs a full round trip from the
 * function. Walking sticker -> revision -> asset -> asset per row made a 30-item page 90+ chained
 * queries; the joins below keep it at one regardless of page size.
 */
export function selectStickerSummaries(db: Database) {
  return db.select({
    sticker: stickerSummaryColumns,
    systemAsset: systemAssetSummaryColumns,
    previewAsset: previewAssetSummaryColumns,
    attachmentMedium: attachmentMediumSummaryColumns,
    attachmentSmall: attachmentSmallSummaryColumns,
    webpAsset: webpSummaryColumns,
    whatsappAsset: whatsappSummaryColumns,
    telegramAsset: telegramSummaryColumns,
  }).from(stickers)
    .leftJoin(stickerRevisions, and(
      eq(stickerRevisions.id, stickers.activeRevisionId),
      eq(stickerRevisions.stickerId, stickers.id),
    ))
    .leftJoin(systemAssets, eq(systemAssets.id, stickerRevisions.systemAssetId))
    .leftJoin(previewAssets, eq(previewAssets.id, previewAssetIdSql))
    .leftJoin(attachmentMediumAssets, eq(attachmentMediumAssets.id, stickerRevisions.attachmentMediumAssetId))
    .leftJoin(attachmentSmallAssets, eq(attachmentSmallAssets.id, stickerRevisions.attachmentSmallAssetId))
    .leftJoin(webpAssets, eq(webpAssets.id, stickerRevisions.webpAssetId))
    .leftJoin(whatsappAssets, eq(whatsappAssets.id, stickerRevisions.whatsappAssetId))
    .leftJoin(telegramAssets, eq(telegramAssets.id, stickerRevisions.telegramAssetId));
}

export type AssetSummary = Pick<typeof assets.$inferSelect,
  "id" | "stickerId" | "kind" | "state" | "mimeType" | "byteSize" | "width" | "height"
  | "frameCount" | "durationSeconds" | "fps" | "sha256" | "hasAlpha" | "createdAt">;

export type StickerSummaryRow = {
  sticker: Pick<typeof stickers.$inferSelect,
    "id" | "title" | "kind" | "status" | "activeRevisionId" | "messengerEmoji" | "createdAt" | "updatedAt">;
  systemAsset: Pick<typeof assets.$inferSelect, "id" | "mimeType" | "byteSize" | "sha256"> | null;
  previewAsset: AssetSummary | null;
  /** Null on anything published before attachment renditions existed. */
  attachmentMedium: AssetSummary | null;
  attachmentSmall: AssetSummary | null;
  /** Null on anything published before WebP exports existed, and on any client that cannot encode one. */
  webpAsset: AssetSummary | null;
  /**
   * The messenger renditions, null until the sticker has been added to a pack — that is when the
   * phone encodes them — and null forever for artwork that overshot a messenger's ceiling. The two
   * are independent: fitting WhatsApp says nothing about fitting Telegram, whose animated budget is
   * half the size.
   */
  whatsappAsset: AssetSummary | null;
  telegramAsset: AssetSummary | null;
};

export interface ListStickersOptions {
  limit?: number;
  cursor?: string | null;
  kind?: "static" | "animated";
  status?: "draft" | "published";
  query?: string | null;
}

/**
 * An attachment rendition is only offered once it is actually downloadable. A `pending` row is a
 * publish that raced its own upload, and handing the extension its id would spend a tap on a 404.
 */
function serializeAttachment(asset: AssetSummary | null) {
  if (!asset || asset.state !== "ready") return null;
  return { ...asset, createdAt: asset.createdAt.toISOString() };
}

export function serializeStickerSummary({
  sticker,
  systemAsset,
  previewAsset,
  attachmentMedium,
  attachmentSmall,
  webpAsset,
  whatsappAsset,
  telegramAsset,
}: StickerSummaryRow) {
  return {
    id: sticker.id,
    title: sticker.title,
    kind: sticker.kind,
    status: sticker.status,
    activeRevisionId: sticker.activeRevisionId,
    createdAt: sticker.createdAt.toISOString(),
    updatedAt: sticker.updatedAt.toISOString(),
    previewAsset: previewAsset ? {
      ...previewAsset,
      createdAt: previewAsset.createdAt.toISOString(),
    } : null,
    systemSticker: systemAsset ? {
      assetId: systemAsset.id,
      mimeType: systemAsset.mimeType,
      byteSize: systemAsset.byteSize,
      sha256: systemAsset.sha256,
    } : null,
    attachmentMedium: serializeAttachment(attachmentMedium),
    attachmentSmall: serializeAttachment(attachmentSmall),
    // Held to the same `ready` gate: an unfinished WebP offered to the extension is a tap spent on
    // a 404, and the APNG it would have fallen back to was there the whole time.
    webpAsset: serializeAttachment(webpAsset),
    // Same gate again, and it matters more here than anywhere: these two are the *only* thing the
    // export sheet can send now that it no longer encodes, so offering one that is not ready would
    // strand a hand-off with nothing to fall back to.
    whatsappAsset: serializeAttachment(whatsappAsset),
    telegramAsset: serializeAttachment(telegramAsset),
    messengerEmoji: sticker.messengerEmoji ?? null,
  };
}

async function serializeSticker(db: Database, sticker: typeof stickers.$inferSelect) {
  const row = await selectStickerSummaries(db).where(eq(stickers.id, sticker.id)).then(firstRow);
  return serializeStickerSummary(row ?? {
    sticker,
    systemAsset: null,
    previewAsset: null,
    attachmentMedium: null,
    attachmentSmall: null,
    webpAsset: null,
    whatsappAsset: null,
    telegramAsset: null,
  });
}

/**
 * Builds the bounded sticker query without executing it.
 *
 * `listLibrarySections` uses this form so its independent reads can share one libSQL batch and one
 * regional round trip. Keep pagination finalization here too, so the batched endpoint and the
 * standalone sticker endpoint cannot drift apart.
 */
export function buildStickerListQuery(
  db: Database,
  ownerId: string,
  options: ListStickersOptions = {},
) {
  const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
  const cursor = decodeCursor(options.cursor);
  const conditions = [eq(stickers.ownerId, ownerId), ne(stickers.status, "deleting")];
  if (options.kind) conditions.push(eq(stickers.kind, options.kind));
  if (options.status) conditions.push(eq(stickers.status, options.status));
  const query = options.query?.trim();
  if (query) conditions.push(sql`strpos(lower(${stickers.title}), lower(${query})) > 0`);
  if (cursor) conditions.push(or(
    lt(stickers.updatedAt, new Date(cursor.updatedAt)),
    and(eq(stickers.updatedAt, new Date(cursor.updatedAt)), lt(stickers.id, cursor.id)),
  )!);
  return {
    limit,
    query: selectStickerSummaries(db).where(and(...conditions))
      .orderBy(desc(stickers.updatedAt), desc(stickers.id)).limit(limit + 1),
  };
}

export function serializeStickerListRows(rows: StickerSummaryRow[], limit: number) {
  const page = rows.slice(0, limit);
  return {
    data: page.map(serializeStickerSummary),
    nextCursor: rows.length > limit && page.length > 0
      ? encodeCursor({ updatedAt: page.at(-1)!.sticker.updatedAt.toISOString(), id: page.at(-1)!.sticker.id })
      : null,
  };
}

export async function listStickers(
  db: Database,
  ownerId: string,
  options: ListStickersOptions = {},
) {
  const selection = buildStickerListQuery(db, ownerId, options);
  return serializeStickerListRows(await selection.query, selection.limit);
}

export async function createSticker(db: Database, ownerId: string, request: CreateStickerRequest) {
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

function intentToJobKind(intent: PostChatMessageRequest["intent"]) {
  if (intent === "generate") return "image" as const;
  if (intent === "animate") return "animation" as const;
  if (intent === "chat") return "chat" as const;
  return "edit" as const;
}

/**
 * The MP4 is deliberately not required here. It is the one rendition nothing on the platform reads:
 * Messages carries the system sticker, the library and share sheet carry the sharing APNG, and the
 * MP4 exists only for somewhere else that plays video. It is also the slowest thing the app renders,
 * so a publish that was never going to share a video does not encode one — see
 * `StickerExportSelection`.
 */
function revisionHasPublishedExports(revision: typeof stickerRevisions.$inferSelect): boolean {
  return Boolean(revision.systemAssetId && (revision.kind === "static"
    ? revision.pngAssetId
    // Either container counts. A sticker published before the switch is no less published for
    // holding a GIF, and demoting it to a draft is what reading only the new column would do.
    : revision.apngAssetId ?? revision.gifAssetId));
}

/** A play-once export has no repeat to separate, so nothing is held. */
function exportHoldSeconds(loop: StickerDocument["loop"]): number {
  return loop === "once" ? 0 : EXPORT_LOOP_HOLD_SECONDS;
}

/** What an export of `document` occupies on a timeline: the motion cycle plus the loop hold. */
export function expectedRenditionDuration(document: Extract<StickerDocument, { kind: "animated" }>): number {
  return document.durationSeconds * (document.loop === "pingPong" ? 2 : 1) + exportHoldSeconds(document.loop);
}

export function validateAnimatedRenditionTiming(
  document: Extract<StickerDocument, { kind: "animated" }>,
  rendition: Pick<typeof assets.$inferSelect, "kind" | "frameCount" | "durationSeconds" | "fps">,
): void {
  if (!rendition.frameCount || !rendition.durationSeconds || !rendition.fps) {
    throw new ApiError(422, "EXPORT_TIMING_UNVERIFIED", "Every animated rendition must have verified frame timing metadata");
  }
  // `speed` divides elapsed time on the way into the interpolator rather than rewriting keyframes,
  // so a document at 2x plays its authored duration in half the wall clock. Exports are wall clock,
  // so the cycle they must match is the authored duration divided by speed — missing this rejects
  // every correctly rendered export of a document that is not playing at 1x.
  const playbackSeconds = document.durationSeconds / Math.max(document.speed, 0.0001);
  const cycleSeconds = playbackSeconds * (document.loop === "pingPong" ? 2 : 1);
  const holdSeconds = exportHoldSeconds(document.loop);
  const expectedDuration = cycleSeconds + holdSeconds;

  // libwebp merges identical adjacent frames and adds their delays. Video sampled above its
  // source cadence commonly produces these duplicates, so encoded frame count is not render FPS.
  // Keep the original grid's duration tolerance; using the merged FPS would allow seconds of drift.
  if (rendition.kind === "webp") {
    if (rendition.frameCount > Math.ceil(cycleSeconds * document.fps) + 1) {
      throw new ApiError(422, "EXPORT_FRAME_COUNT_MISMATCH", "Animated rendition frame count does not match the accepted document cycle");
    }
    if (Math.abs(rendition.durationSeconds - expectedDuration) > 1 / document.fps + 0.01) {
      throw new ApiError(422, "EXPORT_DURATION_MISMATCH", "Animated rendition duration does not match the accepted document cycle and loop hold");
    }
    return;
  }

  // How the hold is spelled depends on what the container can say. GIF and APNG carry a delay per
  // frame, so it rides on the last one and the frame grid still spans exactly the motion cycle. An
  // H.264 track has no such field: AVAssetWriter re-derives every sample's duration from the
  // spacing of the next one, so a final sample asked to last a hold longer is written at the
  // cadence like any other and the file measures exactly the cycle. The only hold an MP4 can state
  // is a repeated frame — see `holdFrameCount` in `StickerGeniOS/Rendering/StickerExporter.swift` —
  // so its grid spans the whole export rather than the cycle.
  const holdFrames = rendition.kind === "mp4" ? Math.round(holdSeconds * document.fps) : 0;

  // Inspection reports fps as frameCount/durationSeconds, which a hold the frames do not cover
  // drags below the grid they were rendered on — recover the grid before comparing to it.
  const gridFps = rendition.frameCount / (holdFrames > 0 ? expectedDuration : cycleSeconds);

  // The sharing apng and the mp4 are rendered at the document's own fps. The system rendition walks a quality ladder
  // to fit under 500 KB, so it is a range rather than a value. The bottom of that ladder is 4 fps —
  // `SystemStickerPreset.adaptive` in `StickerGeniOS/Rendering/StickerExporter.swift` — because a
  // long cycle of dense art that cannot fit at 8 is better shipped choppy than shipped as a still.
  const fpsMatches = rendition.kind === "system"
    ? gridFps >= Math.min(document.fps, 4) - 0.5 && gridFps <= document.fps + 0.75
    : Math.abs(gridFps - document.fps) <= 0.75;
  if (!fpsMatches) throw new ApiError(422, "EXPORT_FPS_MISMATCH", "Animated rendition FPS does not match the accepted document");

  // Only the ladder renditions get to pick their own grid, so everything else has an exact count to
  // hit. This is what catches a frame dropped or duplicated at the ends of the cycle.
  const expectedFrames = Math.ceil(cycleSeconds * document.fps) + holdFrames;
  if (rendition.kind !== "system" && Math.abs(rendition.frameCount - expectedFrames) > 1.01) {
    throw new ApiError(422, "EXPORT_FRAME_COUNT_MISMATCH", "Animated rendition frame count does not match the accepted document cycle");
  }
  const durationTolerance = 1 / gridFps + 0.01;
  if (Math.abs(rendition.durationSeconds - expectedDuration) > durationTolerance) {
    throw new ApiError(422, "EXPORT_DURATION_MISMATCH", "Animated rendition duration does not match the accepted document cycle and loop hold");
  }
}

export async function validateDocumentAssetReferences(
  db: Database,
  ownerId: string,
  stickerId: string,
  document: StickerDocument,
  additionalAssetIds: string[] = [],
): Promise<Map<string, typeof assets.$inferSelect>> {
  const imageLayers = document.layers.filter((layer): layer is Extract<typeof layer, { type: "image" }> => layer.type === "image");
  // v2 grew two more places a document can name an asset. Both are ownership holes if missed: an
  // svg layer can reference uploaded artwork, and the artwork background can reference an image.
  const svgAssetIds = document.layers.flatMap((layer) => (
    layer.type === "svg" && layer.source.kind === "asset" ? [layer.source.assetId] : []
  ));
  const backgroundAssetIds = document.background.type === "image" ? [document.background.assetId] : [];
  const sequenceLayers = document.layers.filter(
    (layer): layer is Extract<typeof layer, { type: "sequence" }> => layer.type === "sequence",
  );
  const videoLayers = document.layers.filter(
    (layer): layer is Extract<typeof layer, { type: "video" }> => layer.type === "video",
  );
  const ids = [...new Set([
    ...additionalAssetIds,
    ...document.layers.flatMap(layerImageAssetIds),
    // The clip: `layerImageAssetIds` reports a video layer's poster, since that is what the server
    // draws, and the MP4 the client plays has to clear the same ownership bar.
    ...document.layers.flatMap(layerVideoAssetIds),
    // The poster is what a pre-v3 client is served in place of the footage, so it has to clear the
    // same ownership bar as everything else the document names.
    ...sequenceLayers.flatMap((layer) => (layer.posterAssetId ? [layer.posterAssetId] : [])),
    ...svgAssetIds,
    ...backgroundAssetIds,
  ])];
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "A document asset belongs to another sticker");
  }
  for (const layer of imageLayers) {
    const image = byId.get(layer.assetId)!;
    if (!new Set(["master", "preview", "reference", "chat_attachment"]).has(image.kind)
      || !AI_REFERENCE_MIME_TYPES.has(image.mimeType)) {
      throw new ApiError(422, "INVALID_LAYER_ASSET", "Image layers must reference ready project image assets");
    }
    if (layer.maskAssetId) {
      const mask = byId.get(layer.maskAssetId)!;
      if (mask.kind !== "mask" || !mask.hasAlpha || (mask.mimeType !== "image/png" && mask.mimeType !== "image/webp")) {
        throw new ApiError(422, "INVALID_LAYER_MASK", "Layer masks must reference validated project mask assets");
      }
      if (mask.width !== image.width || mask.height !== image.height || mask.mimeType !== image.mimeType) {
        throw new ApiError(422, "MASK_DIMENSIONS_MISMATCH", "Layer masks must match their image format and dimensions");
      }
    }
  }
  for (const layer of sequenceLayers) {
    const atlas = byId.get(layer.assetId)!;
    if (atlas.kind !== "sequence" || atlas.mimeType !== "image/png" || !atlas.hasAlpha) {
      throw new ApiError(422, "INVALID_SEQUENCE_ASSET", "Capture layers must reference a validated transparent frame atlas");
    }
    // The layer and the asset row each carry the frame grid, and the renderer trusts the layer while
    // the exporter's timing checks trust neither. If they disagree, the sticker plays footage that
    // is not the footage that was uploaded — so this is a mismatch worth refusing, not reconciling.
    if (
      atlas.frameCount !== layer.frameCount
      || atlas.fps !== layer.frameRate
      || atlas.sequenceColumns !== layer.columns
      || atlas.sequenceRows !== layer.rows
    ) {
      throw new ApiError(
        422,
        "SEQUENCE_METADATA_MISMATCH",
        "A capture layer's grid, frame count, and rate must match the uploaded atlas",
      );
    }
    if (layer.posterAssetId) {
      const poster = byId.get(layer.posterAssetId)!;
      if (poster.mimeType !== "image/png" || !poster.hasAlpha) {
        throw new ApiError(422, "INVALID_SEQUENCE_POSTER", "A capture layer's still frame must be a transparent PNG");
      }
    }
  }
  for (const layer of videoLayers) {
    const clip = byId.get(layer.assetId)!;
    if (clip.kind !== "video" || clip.mimeType !== "video/mp4" || !clip.width || clip.width !== clip.height) {
      throw new ApiError(422, "INVALID_VIDEO_ASSET", "Video layers must reference a validated square generated clip");
    }
    // Same reasoning as the capture check above: the renderer trusts the layer's timing, and the
    // container is the one thing that knows the truth.
    if (clip.frameCount !== layer.frameCount || clip.fps !== layer.frameRate) {
      throw new ApiError(
        422,
        "VIDEO_METADATA_MISMATCH",
        "A video layer's frame count and rate must match the stored clip",
      );
    }
    const poster = byId.get(layer.posterAssetId)!;
    if (poster.mimeType !== "image/png" || !poster.hasAlpha) {
      throw new ApiError(422, "INVALID_VIDEO_POSTER", "A video layer's poster must be a transparent PNG");
    }
  }
  return byId;
}

/**
 * Why animation may not build on a base revision, or `undefined` when it may. Every rejection is a
 * `reason` code plus the values that produced it, because the user-facing consequence — "accept the
 * sticker first" — is only correct for one of them, and the rest are indistinguishable from outside.
 */
async function animationBaseRejection(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<{ reason: string; detail?: Record<string, unknown> } | undefined> {
  if (!baseRevision) return { reason: "no_base_revision" };
  if (baseRevision.stickerId !== sticker.id) {
    return { reason: "base_revision_other_sticker", detail: { baseStickerId: baseRevision.stickerId } };
  }
  if (baseRevision.kind !== "animated") return { reason: "base_revision_not_animated" };
  // A version the user already turned down, or one a later accept swept aside. Acceptance is no
  // longer the gate, so staleness has to be refused in its own right rather than falling out of it.
  if (baseRevision.candidateState !== "accepted" && baseRevision.candidateState !== "candidate") {
    return { reason: "base_revision_decided", detail: { candidateState: baseRevision.candidateState } };
  }
  // Nothing has been kept yet, so the project is a single live branch and this candidate is all
  // there is. This is the "generate, look at it, ask for motion" case: waiting for an accept would
  // make the user decide about the artwork before they are allowed to see it move.
  if (!sticker.activeRevisionId) return undefined;
  const activeRevisionId = sticker.activeRevisionId;
  const active = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, activeRevisionId),
    eq(stickerRevisions.stickerId, sticker.id),
  )).then(firstRow);
  if (!active) return { reason: "active_revision_missing", detail: { activeRevisionId } };
  if (active.candidateState !== "accepted") {
    return { reason: "active_revision_not_accepted", detail: { activeCandidateState: active.candidateState } };
  }
  if (active.kind !== "animated") return { reason: "active_revision_not_animated", detail: { activeKind: active.kind } };
  if (baseRevision.id === active.id) return undefined;

  // Walk the parents back to the kept revision. Every hop must still be a live candidate — that is
  // what stops a request branching off a version the user has already turned down. What produced
  // each hop no longer matters: a candidate from a generate, an edit, or a plan build is as
  // animatable as one from an earlier animation turn.
  let current: typeof stickerRevisions.$inferSelect = baseRevision;
  const visited = new Set<string>();
  const walked: string[] = [];
  for (let depth = 0; depth < 32 && current.id !== active.id; depth += 1) {
    walked.push(current.id);
    if (visited.has(current.id)) return { reason: "parent_chain_cycle", detail: { walked } };
    if (current.candidateState !== "candidate") {
      return { reason: "chain_revision_not_candidate", detail: { walked, candidateState: current.candidateState } };
    }
    if (!current.parentRevisionId) return { reason: "chain_revision_has_no_parent", detail: { walked } };
    visited.add(current.id);
    const parent = await db.select().from(stickerRevisions).where(and(
      eq(stickerRevisions.id, current.parentRevisionId),
      eq(stickerRevisions.stickerId, sticker.id),
    )).then(firstRow);
    if (!parent) return { reason: "parent_revision_missing", detail: { walked, parentRevisionId: current.parentRevisionId } };
    current = parent;
  }
  if (current.id !== active.id) return { reason: "parent_chain_depth_exceeded", detail: { walked } };
  return undefined;
}

/**
 * Whether animation may build on `baseRevision`: the kept revision, or a live candidate descended
 * from it — including a first generation nothing has been accepted from yet.
 *
 * Exposed as a predicate as well as the assertion below because the chat router decides to animate
 * from the user's words alone, with no view of what has been accepted. A turn it routes that way has
 * already been committed to the transcript, so it needs to ask the question and answer the user,
 * where a request carrying an explicit animate intent is simply rejected.
 */
export async function isValidAnimationBase(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<boolean> {
  const rejection = await animationBaseRejection(db, sticker, baseRevision);
  if (!rejection) return true;
  console.warn("Rejected an animation base", {
    ...rejection.detail,
    reason: rejection.reason,
    stickerId: sticker.id,
    stickerKind: sticker.kind,
    activeRevisionId: sticker.activeRevisionId,
    baseRevisionId: baseRevision?.id,
    baseRevisionKind: baseRevision?.kind,
    baseRevisionCandidateState: baseRevision?.candidateState,
    baseRevisionParentId: baseRevision?.parentRevisionId,
    baseRevisionSourceMessageId: baseRevision?.sourceMessageId,
  });
  return false;
}

export async function assertValidAnimationBase(
  db: Database,
  sticker: typeof stickers.$inferSelect,
  baseRevision?: typeof stickerRevisions.$inferSelect,
): Promise<void> {
  if (await isValidAnimationBase(db, sticker, baseRevision)) return;
  // The code is unchanged on purpose: clients key on it, and "not accepted" is still the shape of
  // the failure even though acceptance itself is no longer what is being asserted.
  throw new ApiError(
    422,
    "ANIMATION_BASE_NOT_ACCEPTED",
    "Animation must build on a live revision of this sticker: the current one, or a candidate descended from it",
  );
}

export async function createChatTurn(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PostChatMessageRequest,
  appClip = false,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
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
    await db.transaction(async (tx) => {
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
        kind: request.intent === "animate"
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
      await tx.update(stickers).set({ updatedAt: now }).where(eq(stickers.id, stickerId));
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

export async function bindExports(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: PublishExportsRequest,
  publishedRevisionId = crypto.randomUUID(),
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  const existingPublished = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, publishedRevisionId)).then(firstRow);
  if (existingPublished) {
    if (existingPublished.stickerId !== stickerId || existingPublished.parentRevisionId !== request.revisionId) {
      throw new ApiError(409, "PUBLISHED_REVISION_CONFLICT", "The deterministic published revision ID belongs to another export");
    }
    return { stickerId, revisionId: existingPublished.id, sourceRevisionId: request.revisionId, status: "published" as const };
  }
  if (sticker.activeRevisionId !== request.revisionId) {
    throw new ApiError(409, "REVISION_NOT_ACTIVE", "Exports may only be published for the active revision");
  }
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.revisionId),
    eq(stickerRevisions.stickerId, stickerId),
    eq(stickerRevisions.candidateState, "accepted"),
  )).then(firstRow);
  if (!revision) throw new ApiError(409, "REVISION_NOT_ACCEPTED", "The revision must be accepted before publishing");
  const ids = [
    request.pngAssetId,
    request.apngAssetId,
    request.mp4AssetId,
    request.systemAssetId,
    request.attachmentMediumAssetId,
    request.attachmentSmallAssetId,
    request.webpAssetId,
  ].filter((value): value is string => Boolean(value));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "An export belongs to another sticker");
  }
  const system = byId.get(request.systemAssetId)!;
  if (system.kind !== "system" || (system.byteSize ?? Infinity) >= 500_000) {
    throw new ApiError(422, "INVALID_SYSTEM_STICKER", "A verified system rendition below 500 KB is required");
  }
  // Only `apng` is accepted for a *new* publish. Revisions that already point at a `gif` asset keep
  // resolving through the same column — see `0009_apng_sharing_rendition.sql` — but nothing writes
  // one any more, so admitting the old kind here would only let a stale client publish a container
  // the rest of this file no longer describes.
  if (request.apngAssetId && byId.get(request.apngAssetId)?.kind !== "apng") {
    throw new ApiError(422, "INVALID_APNG_EXPORT", "Sharing APNG export asset is invalid");
  }
  if (request.mp4AssetId && byId.get(request.mp4AssetId)?.kind !== "mp4") throw new ApiError(422, "INVALID_MP4_EXPORT", "MP4 export asset is invalid");
  if (request.pngAssetId && byId.get(request.pngAssetId)?.kind !== "master") throw new ApiError(422, "INVALID_PNG_EXPORT", "PNG export asset is invalid");
  // The two smaller sends. `validateImageForKind` already proved each one is a transparent square
  // PNG at 408 or 300; what it could not know is *which* column it was headed for, so the pairing
  // is checked here. Getting them the wrong way round would silently hand someone Small when they
  // asked for Medium.
  for (const [field, assetId] of [
    ["attachmentMediumAssetId", request.attachmentMediumAssetId],
    ["attachmentSmallAssetId", request.attachmentSmallAssetId],
  ] as const) {
    if (!assetId) continue;
    const asset = byId.get(assetId)!;
    if (asset.kind !== "attachment") {
      throw new ApiError(422, "INVALID_ATTACHMENT_EXPORT", `${field} must reference an attachment rendition`);
    }
    const expected = field === "attachmentMediumAssetId"
      ? ATTACHMENT_RENDITION_DIMENSIONS.medium
      : ATTACHMENT_RENDITION_DIMENSIONS.small;
    if (asset.width !== expected) {
      throw new ApiError(422, "INVALID_ATTACHMENT_SIZE", `${field} must be ${expected} pixels wide`);
    }
    // An attachment rendition is a copy of the sharing rendition, so it moves exactly when the
    // sticker does. A still one under an animated sticker is the wrong file, and an animated one
    // under a static sticker could not have been rendered from that document at all.
    if ((revision.kind === "animated") !== ((asset.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "ATTACHMENT_RENDITION_MISMATCH",
        `${field} must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  // Optional by construction — iOS has no system WebP encoder, so a client that cannot link one
  // publishes without this and its `.image` sends keep resolving to the APNG. What is checked is
  // that a WebP which *did* arrive is the right file: the kind it claims, and moving (or not) with
  // the sticker exactly as the attachment renditions must.
  if (request.webpAssetId) {
    const webp = byId.get(request.webpAssetId)!;
    if (webp.kind !== "webp") {
      throw new ApiError(422, "INVALID_WEBP_EXPORT", "webpAssetId must reference a WebP rendition");
    }
    if ((revision.kind === "animated") !== ((webp.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "WEBP_RENDITION_MISMATCH",
        `webpAssetId must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  if (revision.kind === "static" && !request.pngAssetId) throw new ApiError(422, "PNG_EXPORT_REQUIRED", "Static stickers require a rendered PNG export");
  if (revision.kind === "static" && (request.apngAssetId || request.mp4AssetId)) {
    throw new ApiError(422, "STATIC_EXPORT_MATRIX", "Static stickers only accept PNG and single-frame PNG system renditions");
  }
  if (revision.kind === "static" && (system.mimeType !== "image/png" || (system.frameCount ?? 1) !== 1)) {
    throw new ApiError(422, "STATIC_SYSTEM_RENDITION_REQUIRED", "Static stickers require a single-frame PNG system rendition");
  }
  // The MP4 is optional: an export that is only ever going to be a sticker has no video to publish,
  // and encoding one anyway is the slowest step in a publish. The sharing APNG is not — it is what
  // the library, the share sheet and every non-Messages surface show for an animated sticker.
  if (revision.kind === "animated" && !request.apngAssetId) {
    throw new ApiError(422, "ANIMATED_EXPORTS_REQUIRED", "Animated stickers require a sharing APNG export");
  }
  if (revision.kind === "animated" && request.pngAssetId) {
    throw new ApiError(422, "ANIMATED_EXPORT_MATRIX", "Animated stickers do not accept a static PNG export relation");
  }
  // An animated sticker normally carries an animated system rendition, and a single-frame one is a
  // client that uploaded the wrong file — unless the client says otherwise. Some animations cannot
  // be squeezed under Apple's 500 KB ceiling at any size or frame rate the ladder can reach, and the
  // app ships their poster frame rather than refusing to export at all. The sharing APNG and MP4
  // renditions still carry the full motion, so nothing about the sticker is lost outside Messages.
  const systemIsStill = request.systemRenditionKind === "still";
  if (revision.kind === "animated" && !systemIsStill && (system.frameCount ?? 0) < 2) {
    throw new ApiError(422, "ANIMATED_SYSTEM_RENDITION_REQUIRED", "Animated stickers require an animated system rendition");
  }
  if (systemIsStill && (revision.kind !== "animated" || (system.frameCount ?? 1) !== 1)) {
    throw new ApiError(422, "INVALID_STILL_SYSTEM_RENDITION", "A still system rendition is only accepted as an animated sticker's single-frame fallback");
  }
  if (revision.kind === "animated" && !request.mp4Background) {
    throw new ApiError(422, "MP4_BACKGROUND_REQUIRED", "Animated exports must record the MP4 background used by the renderer");
  }
  if (revision.kind === "static" && request.mp4Background) {
    throw new ApiError(422, "MP4_BACKGROUND_NOT_ALLOWED", "Static exports do not use an MP4 background");
  }
  if (revision.kind === "animated") {
    const document = StickerDocumentSchema.parse(revision.documentJson);
    if (document.kind !== "animated") {
      throw new ApiError(422, "REVISION_KIND_MISMATCH", "Animated revision metadata must contain an animated sticker document");
    }
    // Counted through the shared helper rather than by hand: this sum used to omit `trim`, which
    // rejected a perfectly good draw-on-only sticker here with a confusing 422.
    const keyframeCount = document.layers.reduce((total, layer) => total + countKeyframes(layer.animation), 0);
    if (keyframeCount === 0) {
      throw new ApiError(422, "ANIMATION_KEYFRAMES_REQUIRED", "Animated exports require at least one accepted animation keyframe");
    }
    for (const assetId of [
      request.apngAssetId,
      request.mp4AssetId,
      request.systemAssetId,
      // Held to the document's own grid exactly like the sharing rendition they are copies of.
      // Nothing here is under the 500 KB ceiling, so unlike the system sticker they never traded
      // frame rate away and a mismatch really is a bad export.
      request.attachmentMediumAssetId,
      request.attachmentSmallAssetId,
      // WebP preserves the cycle duration but may merge repeated frames.
      request.webpAssetId,
    ]) {
      if (!assetId) continue;
      // The still fallback has no cycle to match; it is one frame standing in for all of them.
      if (systemIsStill && assetId === request.systemAssetId) continue;
      validateAnimatedRenditionTiming(document, byId.get(assetId)!);
    }
  }

  const sourceDocument = StickerDocumentSchema.parse(revision.documentJson);
  await validateDocumentAssetReferences(db, ownerId, stickerId, sourceDocument, [
    revision.masterAssetId,
    revision.previewAssetId,
  ].filter((value): value is string => Boolean(value)));
  const publishedDocument = StickerDocumentSchema.parse(revision.kind === "animated"
    ? { ...sourceDocument, mp4Background: request.mp4Background }
    : sourceDocument);
  await db.transaction(async (tx) => {
    await tx.insert(stickerRevisions).values({
      id: publishedRevisionId,
      stickerId,
      parentRevisionId: request.revisionId,
      kind: revision.kind,
      candidateState: "accepted",
      documentJson: publishedDocument,
      masterAssetId: revision.masterAssetId,
      previewAssetId: revision.previewAssetId,
      pngAssetId: request.pngAssetId,
      apngAssetId: request.apngAssetId,
      mp4AssetId: request.mp4AssetId,
      systemAssetId: request.systemAssetId,
      attachmentMediumAssetId: request.attachmentMediumAssetId,
      attachmentSmallAssetId: request.attachmentSmallAssetId,
      webpAssetId: request.webpAssetId,
      createdAt: new Date(),
      decidedAt: new Date(),
    });
    const published = await tx.update(stickers).set({
      activeRevisionId: publishedRevisionId,
      status: "published",
      updatedAt: new Date(),
    }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
      eq(stickers.activeRevisionId, request.revisionId),
      ne(stickers.status, "deleting"),
    )).returning({ id: stickers.id });
    if (published.length === 0) {
      throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision changed before exports could be published");
    }
  });
  return { stickerId, revisionId: publishedRevisionId, sourceRevisionId: request.revisionId, status: "published" as const };
}

/**
 * Attaches the WhatsApp and Telegram renditions to a sticker's already-published revision.
 *
 * Deliberately *not* part of `bindExports`. That function mints a new published revision out of an
 * accepted candidate and charges an export job for it; these files arrive much later, when an
 * already-published sticker is put into a pack, and there is nothing new to publish — only two
 * empty columns to fill on the revision that is already active.
 *
 * Which makes this the one place in this file that mutates a published revision in place. It is
 * safe because of what it is allowed to do: it only ever writes these two columns, they take no
 * part in the preview-resolution chain, and the `activeRevisionId` guard in both statements means a
 * device edit that lands first wins — the bind then fails rather than stapling renditions onto
 * artwork that has already moved on. Anyone extending this to a third column should re-read that
 * sentence first.
 *
 * Every field is optional and independent. Artwork that fits WhatsApp's 500 KB animated ceiling
 * regularly misses Telegram's 256 KB one, and binding the rendition that worked is strictly better
 * than refusing both — a pack that can go to one messenger is not a failed pack.
 */
export async function bindMessengerRenditions(
  db: Database,
  ownerId: string,
  stickerId: string,
  request: MessengerRenditionsRequest,
) {
  const sticker = await assertOwnedSticker(db, ownerId, stickerId);
  if (sticker.status !== "published") {
    throw new ApiError(409, "STICKER_NOT_PUBLISHED", "Messenger renditions belong to a published sticker");
  }
  if (sticker.activeRevisionId !== request.revisionId) {
    throw new ApiError(409, "REVISION_NOT_ACTIVE", "Messenger renditions may only be bound to the active revision");
  }
  const revision = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.id, request.revisionId),
    eq(stickerRevisions.stickerId, stickerId),
  )).then(firstRow);
  if (!revision) throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision could not be read");

  const ids = [request.whatsappAssetId, request.telegramAssetId].filter((value): value is string => Boolean(value));
  const rows = await getReadyOwnedAssets(db, ownerId, ids);
  const byId = new Map(rows.map((asset) => [asset.id, asset]));
  for (const asset of rows) {
    if (asset.stickerId !== stickerId) throw new ApiError(422, "ASSET_STICKER_MISMATCH", "A messenger rendition belongs to another sticker");
  }

  // `completeUpload` already proved each file is a transparent 512 px square inside its messenger's
  // byte ceiling. What it could not know is which *sticker* it was headed for, so the one thing left
  // is that the rendition moves with this one: a still file under an animated sticker would be
  // handed to a pack the messenger has been told is animated, and rejected on arrival.
  const whatsapp = request.whatsappAssetId ? byId.get(request.whatsappAssetId)! : undefined;
  if (whatsapp) {
    if (whatsapp.kind !== "messenger_whatsapp") {
      throw new ApiError(422, "INVALID_WHATSAPP_RENDITION", "whatsappAssetId must reference a WhatsApp rendition");
    }
    if ((revision.kind === "animated") !== ((whatsapp.frameCount ?? 1) > 1)) {
      throw new ApiError(
        422,
        "WHATSAPP_RENDITION_MISMATCH",
        `whatsappAssetId must be ${revision.kind === "animated" ? "animated" : "a single frame"} to match the sticker`,
      );
    }
  }
  const telegram = request.telegramAssetId ? byId.get(request.telegramAssetId)! : undefined;
  if (telegram) {
    if (telegram.kind !== "messenger_telegram") {
      throw new ApiError(422, "INVALID_TELEGRAM_RENDITION", "telegramAssetId must reference a Telegram rendition");
    }
    // Telegram is the one destination where the container itself is the discriminator: a static
    // sticker goes as a still PNG and an animated one as a VP9 WebM. `frameCount` cannot arbitrate
    // — a WebM never reports one, because counting its frames means walking every cluster block —
    // so the mime type is what the two kinds are told apart by, and it is exact.
    const expected = revision.kind === "animated" ? "video/webm" : "image/png";
    if (telegram.mimeType !== expected) {
      throw new ApiError(
        422,
        "TELEGRAM_RENDITION_MISMATCH",
        `telegramAssetId must be ${expected} to match ${revision.kind === "animated" ? "an animated" : "a static"} sticker`,
      );
    }
  }

  const now = new Date();
  await db.transaction(async (tx) => {
    // Only the fields that arrived are written. An emoji-only call must not blank the renditions,
    // and a rendition-only call must not blank the emoji.
    const revisionPatch: Partial<typeof stickerRevisions.$inferInsert> = {};
    if (request.whatsappAssetId) revisionPatch.whatsappAssetId = request.whatsappAssetId;
    if (request.telegramAssetId) revisionPatch.telegramAssetId = request.telegramAssetId;
    if (Object.keys(revisionPatch).length > 0) {
      await tx.update(stickerRevisions).set(revisionPatch).where(and(
        eq(stickerRevisions.id, request.revisionId),
        eq(stickerRevisions.stickerId, stickerId),
      ));
    }
    // The emoji rides along on the sticker rather than the revision, so this is a second statement
    // — and the one that carries the `activeRevisionId` guard for the whole call. A racing device
    // edit moves the active revision, this matches nothing, and the bind is refused.
    const touched = await tx.update(stickers).set({
      ...(request.emoji ? { messengerEmoji: request.emoji } : {}),
      updatedAt: now,
    }).where(and(
      eq(stickers.id, stickerId),
      eq(stickers.ownerId, ownerId),
      eq(stickers.activeRevisionId, request.revisionId),
      ne(stickers.status, "deleting"),
    )).returning({ id: stickers.id });
    if (touched.length === 0) {
      throw new ApiError(409, "REVISION_NOT_ACTIVE", "The active revision changed before the renditions could be bound");
    }
  });

  // The whole summary, not an acknowledgement: the client just learned this sticker is sendable and
  // would otherwise have to re-list the pack to find out.
  const row = await selectStickerSummaries(db).where(eq(stickers.id, stickerId)).then(firstRow);
  if (!row) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");
  return serializeStickerSummary(row);
}
