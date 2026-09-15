// Sticker rows as the API returns them: the column sets every listing selects, the cursor it
// pages with, and the shape of a summary. The ceilings on what may be handed to a model live
// here too, because they are properties of an asset row rather than of any one operation.

import { and, desc, eq, lt, ne, or, sql } from "drizzle-orm";
import { firstRow, type Database } from "@/lib/db/client";
import { attachmentMediumAssets, attachmentSmallAssets, previewAssetIdSql, previewAssets, telegramAssets, webpAssets, whatsappAssets, systemAssets } from "@/lib/db/columns";
import { assets, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

export const MAX_AI_INPUT_BYTES = 32 * 1024 * 1024;
export const AI_REFERENCE_MIME_TYPES = new Set(["image/png", "image/jpeg", "image/webp"]);

/**
 * The asset kinds a user may attach to a turn as visual input.
 *
 * `sequence` belongs here for a reason worth stating: a frame atlas is a PNG contact sheet, so it
 * reaches the model as an ordinary image and the model can *read the motion off it* the way a
 * person reads a storyboard. That is the property the whole sprite-sheet transport was chosen for,
 * and it is why no other part of the AI path — bounds checks, MIME allowlists, reference loading —
 * needed widening to support captured footage.
 */
export const AI_INPUT_ASSET_KINDS = new Set(["reference", "chat_attachment", "sequence"]);

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
    playbackRevisionId: sql<string | null>`CASE WHEN ${stickerRevisions.playbackJson} IS NOT NULL THEN ${stickerRevisions.id} ELSE NULL END`,
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
  playbackRevisionId?: string | null;
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
  playbackRevisionId,
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
    playbackRevisionId: playbackRevisionId ?? null,
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

export async function serializeSticker(db: Database, sticker: typeof stickers.$inferSelect) {
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
