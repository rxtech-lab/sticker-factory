import { and, asc, count, desc, eq, inArray, isNull, lt, ne, or, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import {
  attachmentMediumAssets,
  attachmentSmallAssets,
  previewAssetIdSql,
  previewAssets,
  systemAssets,
} from "@/lib/db/columns";
import {
  creatorProfiles,
  packInstalls,
  stickerPackItems,
  stickerPacks,
  stickerRevisions,
  stickers,
  users,
  type CreatorProfileRow,
  type StickerPackRow,
} from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  attachmentMediumSummaryColumns,
  attachmentSmallSummaryColumns,
  listStickers,
  previewAssetSummaryColumns,
  serializeStickerSummary,
  stickerSummaryColumns,
  systemAssetSummaryColumns,
  type StickerSummaryRow,
} from "@/lib/services/stickers";

/** A pack is a curated set, not a dumping ground; the Messages grid also has to stay scrollable. */
export const MAX_PACK_ITEMS = 60;
/** Enough for any real user, low enough that `listLibrarySections` stays a bounded query. */
export const MAX_INSTALLED_PACKS = 30;
/** Cover tiles shown on a browse card. */
const COVER_STICKER_COUNT = 4;

/** Pack states a non-creator may see. `draft` and `removed` are creator-only. */
const PUBLIC_PACK_STATES = ["published", "unlisted"] as const;

type PackSort = "recent" | "popular";

export interface PackCursor {
  sortKey: string;
  id: string;
}

function encodePackCursor(cursor: PackCursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodePackCursor(cursor?: string | null): PackCursor | undefined {
  if (!cursor) return undefined;
  try {
    const parsed = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8")) as PackCursor;
    if (typeof parsed?.sortKey !== "string" || typeof parsed?.id !== "string") throw new Error("malformed");
    return parsed;
  } catch {
    throw new ApiError(400, "INVALID_CURSOR", "The pagination cursor is not valid");
  }
}

// ---------------------------------------------------------------------------
// Creator identity
// ---------------------------------------------------------------------------

function slugifyHandleBase(source: string | null): string {
  const base = (source ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 24);
  return base.length >= 3 ? base : "creator";
}

/**
 * The creator's profile row, minting one on first use.
 *
 * The handle is derived from `users.display_name` and *never* from the email — the email is PII
 * and the handle is public. A short random suffix keeps two users named "Alex" apart.
 */
export async function ensureCreatorProfile(db: Database, userId: string): Promise<CreatorProfileRow> {
  const existing = await db.select().from(creatorProfiles).where(eq(creatorProfiles.userId, userId)).get();
  if (existing) return existing;

  const user = await db.select({ displayName: users.displayName }).from(users).where(eq(users.id, userId)).get();
  const base = slugifyHandleBase(user?.displayName ?? null);
  const now = new Date();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const suffix = crypto.randomUUID().replace(/-/g, "").slice(0, 6);
    const handle = `${base}-${suffix}`;
    try {
      const inserted = await db.insert(creatorProfiles)
        .values({ userId, handle, createdAt: now, updatedAt: now })
        .returning()
        .get();
      if (inserted) return inserted;
    } catch {
      // Either the handle collided or another request created the profile first. Re-read before
      // burning another attempt: the common case is a concurrent create, not a real collision.
      const raced = await db.select().from(creatorProfiles).where(eq(creatorProfiles.userId, userId)).get();
      if (raced) return raced;
    }
  }

  const fallback = `creator-${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
  return db.insert(creatorProfiles)
    .values({ userId, handle: fallback, createdAt: now, updatedAt: now })
    .returning()
    .get() as Promise<CreatorProfileRow>;
}

type CreatorRow = {
  profile: CreatorProfileRow | null;
  user: { id: string; displayName: string | null } | null;
};

export interface CreatorV1 {
  handle: string;
  displayName: string;
  bio: string | null;
  packCount: number;
  isSelf: boolean;
}

/**
 * The public creator byline.
 *
 * `creator_profiles.display_name` wins over the legacy `users.display_name`. New user rows are
 * id-only because OAuth remains the profile source of truth. The handle is the last resort, so the
 * result is never blank — and the email is never a fallback.
 */
export function serializeCreator(
  { profile, user }: CreatorRow,
  options: { viewerId: string; packCount?: number },
): CreatorV1 {
  const handle = profile?.handle ?? "unknown";
  return {
    handle,
    displayName: profile?.displayName?.trim() || user?.displayName?.trim() || `@${handle}`,
    bio: profile?.bio ?? null,
    packCount: options.packCount ?? 0,
    isSelf: user?.id === options.viewerId,
  };
}

export async function getCreatorByHandle(db: Database, handle: string) {
  const row = await db.select({ profile: creatorProfiles, user: users })
    .from(creatorProfiles)
    .innerJoin(users, eq(users.id, creatorProfiles.userId))
    .where(eq(creatorProfiles.handle, handle))
    .get();
  if (!row) throw new ApiError(404, "CREATOR_NOT_FOUND", "Creator not found");
  const packCount = await db.select({ value: count() }).from(stickerPacks)
    .where(and(eq(stickerPacks.creatorId, row.user.id), inArray(stickerPacks.state, [...PUBLIC_PACK_STATES])))
    .get();
  return { ...row, packCount: packCount?.value ?? 0 };
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

export interface PackSummaryV1 {
  id: string;
  slug: string;
  title: string;
  summary: string | null;
  state: StickerPackRow["state"];
  creator: CreatorV1;
  itemCount: number;
  installCount: number;
  installed: boolean;
  isMine: boolean;
  coverStickers: ReturnType<typeof serializeStickerSummary>[];
  monetization: { kind: StickerPackRow["monetization"]; priceCents: number; currency: string };
  publishedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface PackDetailV1 extends PackSummaryV1 {
  stickers: ReturnType<typeof serializeStickerSummary>[];
}

type PackJoinRow = {
  pack: StickerPackRow;
  profile: CreatorProfileRow | null;
  user: { id: string; displayName: string | null } | null;
};

function serializePackSummary(
  row: PackJoinRow,
  options: { viewerId: string; installed: boolean; coverStickers: StickerSummaryRow[] },
): PackSummaryV1 {
  const { pack } = row;
  return {
    id: pack.id,
    slug: pack.slug,
    title: pack.title,
    summary: pack.summary,
    state: pack.state,
    creator: serializeCreator(row, { viewerId: options.viewerId }),
    itemCount: pack.itemCount,
    installCount: pack.installCount,
    installed: options.installed,
    isMine: pack.creatorId === options.viewerId,
    coverStickers: options.coverStickers.map(serializeStickerSummary),
    monetization: { kind: pack.monetization, priceCents: pack.priceCents, currency: pack.currency },
    publishedAt: pack.publishedAt?.toISOString() ?? null,
    createdAt: pack.createdAt.toISOString(),
    updatedAt: pack.updatedAt.toISOString(),
  };
}

function selectPacks(db: Database) {
  return db.select({ pack: stickerPacks, profile: creatorProfiles, user: users })
    .from(stickerPacks)
    .innerJoin(users, eq(users.id, stickerPacks.creatorId))
    .leftJoin(creatorProfiles, eq(creatorProfiles.userId, stickerPacks.creatorId));
}

/**
 * Every pack's members, resolved in one statement per call rather than one per pack.
 *
 * The system-asset join is INNER on purpose: it is the single guard that already excludes a
 * sticker demoted back to `draft` by a device edit, because that sticker's new active revision
 * carries no `system_asset_id` at all. The status and tombstone predicates are deliberately
 * redundant on top of it.
 */
async function loadPackMembers(
  db: Database,
  packIds: string[],
  options: { perPack?: number; query?: string | null } = {},
): Promise<Map<string, StickerSummaryRow[]>> {
  const byPack = new Map<string, StickerSummaryRow[]>();
  if (packIds.length === 0) return byPack;
  const conditions = [
    inArray(stickerPackItems.packId, packIds),
    eq(stickers.status, "published"),
    isNull(stickers.deletedAt),
  ];
  const query = options.query?.trim();
  if (query) conditions.push(sql`instr(lower(${stickers.title}), lower(${query})) > 0`);
  const rows = await db.select({
    packId: stickerPackItems.packId,
    position: stickerPackItems.position,
    sticker: stickerSummaryColumns,
    systemAsset: systemAssetSummaryColumns,
    previewAsset: previewAssetSummaryColumns,
    attachmentMedium: attachmentMediumSummaryColumns,
    attachmentSmall: attachmentSmallSummaryColumns,
  })
    .from(stickerPackItems)
    .innerJoin(stickers, eq(stickers.id, stickerPackItems.stickerId))
    .innerJoin(stickerRevisions, eq(stickerRevisions.id, stickers.activeRevisionId))
    .innerJoin(systemAssets, and(
      eq(systemAssets.id, stickerRevisions.systemAssetId),
      eq(systemAssets.state, "ready"),
    ))
    .leftJoin(previewAssets, eq(previewAssets.id, previewAssetIdSql))
    .leftJoin(attachmentMediumAssets, eq(attachmentMediumAssets.id, stickerRevisions.attachmentMediumAssetId))
    .leftJoin(attachmentSmallAssets, eq(attachmentSmallAssets.id, stickerRevisions.attachmentSmallAssetId))
    .where(and(...conditions))
    .orderBy(asc(stickerPackItems.packId), asc(stickerPackItems.position), asc(stickerPackItems.stickerId));

  const perPack = options.perPack ?? MAX_PACK_ITEMS;
  for (const row of rows) {
    const bucket = byPack.get(row.packId) ?? [];
    if (bucket.length >= perPack) continue;
    bucket.push({
      sticker: row.sticker,
      systemAsset: row.systemAsset,
      previewAsset: row.previewAsset,
      attachmentMedium: row.attachmentMedium,
      attachmentSmall: row.attachmentSmall,
    });
    byPack.set(row.packId, bucket);
  }
  for (const packId of packIds) if (!byPack.has(packId)) byPack.set(packId, []);
  return byPack;
}

async function loadInstalledPackIds(db: Database, viewerId: string, packIds: string[]): Promise<Set<string>> {
  if (packIds.length === 0) return new Set();
  const rows = await db.select({ packId: packInstalls.packId }).from(packInstalls).where(and(
    eq(packInstalls.userId, viewerId),
    eq(packInstalls.state, "installed"),
    inArray(packInstalls.packId, packIds),
  ));
  return new Set(rows.map((row) => row.packId));
}

async function serializePackPage(db: Database, rows: PackJoinRow[], viewerId: string): Promise<PackSummaryV1[]> {
  const packIds = rows.map((row) => row.pack.id);
  const [members, installed] = await Promise.all([
    loadPackMembers(db, packIds, { perPack: COVER_STICKER_COUNT }),
    loadInstalledPackIds(db, viewerId, packIds),
  ]);
  return rows.map((row) => serializePackSummary(row, {
    viewerId,
    installed: installed.has(row.pack.id),
    coverStickers: members.get(row.pack.id) ?? [],
  }));
}

// ---------------------------------------------------------------------------
// Browse
// ---------------------------------------------------------------------------

/**
 * A title contains-match, or `undefined` for a query that asks for nothing.
 *
 * The wildcards are escaped: `%` and `_` are ordinary characters in a search field, and left raw a
 * lone `%` would quietly match every pack there is.
 */
function titleSearch(query: string | null | undefined) {
  const trimmed = query?.trim();
  if (!trimmed) return undefined;
  const escaped = trimmed.replace(/[\\%_]/g, (character) => `\\${character}`);
  return sql`${stickerPacks.title} LIKE ${`%${escaped}%`} ESCAPE '\\'`;
}

export async function listMarketplacePacks(
  db: Database,
  viewerId: string,
  options: { limit?: number; cursor?: string | null; sort?: PackSort; query?: string | null } = {},
) {
  const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
  const sort = options.sort ?? "recent";
  const cursor = decodePackCursor(options.cursor);
  const conditions = [eq(stickerPacks.state, "published")];
  const search = titleSearch(options.query);
  if (search) conditions.push(search);

  // Popularity and recency need different cursor keys, but both stay (key, id) so ties are stable.
  const sortColumn = sort === "popular" ? stickerPacks.installCount : stickerPacks.publishedAt;
  if (cursor) {
    const value = sort === "popular" ? Number(cursor.sortKey) : new Date(cursor.sortKey);
    conditions.push(or(
      lt(sortColumn, value as never),
      and(eq(sortColumn, value as never), lt(stickerPacks.id, cursor.id)),
    )!);
  }

  const rows = await selectPacks(db).where(and(...conditions))
    .orderBy(desc(sortColumn), desc(stickerPacks.id))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const last = page.at(-1);
  return {
    data: await serializePackPage(db, page, viewerId),
    nextCursor: rows.length > limit && last
      ? encodePackCursor({
        sortKey: sort === "popular" ? String(last.pack.installCount) : (last.pack.publishedAt ?? last.pack.createdAt).toISOString(),
        id: last.pack.id,
      })
      : null,
  };
}

/** The creator's own packs, in every state, newest first. Searchable by title, as browse is. */
export async function listOwnPacks(
  db: Database,
  creatorId: string,
  options: { limit?: number; cursor?: string | null; query?: string | null } = {},
) {
  const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
  const cursor = decodePackCursor(options.cursor);
  const conditions = [eq(stickerPacks.creatorId, creatorId), ne(stickerPacks.state, "removed")];
  const search = titleSearch(options.query);
  if (search) conditions.push(search);
  if (cursor) {
    const updatedAt = new Date(cursor.sortKey);
    conditions.push(or(
      lt(stickerPacks.updatedAt, updatedAt),
      and(eq(stickerPacks.updatedAt, updatedAt), lt(stickerPacks.id, cursor.id)),
    )!);
  }
  const rows = await selectPacks(db).where(and(...conditions))
    .orderBy(desc(stickerPacks.updatedAt), desc(stickerPacks.id))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const last = page.at(-1);
  return {
    data: await serializePackPage(db, page, creatorId),
    nextCursor: rows.length > limit && last
      ? encodePackCursor({ sortKey: last.pack.updatedAt.toISOString(), id: last.pack.id })
      : null,
  };
}

export async function listPacksByCreator(
  db: Database,
  viewerId: string,
  handle: string,
  options: { limit?: number; cursor?: string | null } = {},
) {
  const { profile, user, packCount } = await getCreatorByHandle(db, handle);
  // Viewing your own creator page shows drafts too; everyone else sees only what is public.
  const isSelf = user.id === viewerId;
  const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
  const cursor = decodePackCursor(options.cursor);
  const conditions = [
    eq(stickerPacks.creatorId, user.id),
    isSelf ? ne(stickerPacks.state, "removed") : inArray(stickerPacks.state, [...PUBLIC_PACK_STATES]),
  ];
  if (cursor) {
    const updatedAt = new Date(cursor.sortKey);
    conditions.push(or(
      lt(stickerPacks.updatedAt, updatedAt),
      and(eq(stickerPacks.updatedAt, updatedAt), lt(stickerPacks.id, cursor.id)),
    )!);
  }
  const rows = await selectPacks(db).where(and(...conditions))
    .orderBy(desc(stickerPacks.updatedAt), desc(stickerPacks.id))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const last = page.at(-1);
  return {
    creator: serializeCreator({ profile, user }, { viewerId, packCount }),
    data: await serializePackPage(db, page, viewerId),
    nextCursor: rows.length > limit && last
      ? encodePackCursor({ sortKey: last.pack.updatedAt.toISOString(), id: last.pack.id })
      : null,
  };
}

/** A pack by id or slug. Non-creators may only reach `published`/`unlisted` packs. */
export async function getPack(db: Database, viewerId: string, packRef: string): Promise<PackDetailV1> {
  const row = await selectPacks(db)
    .where(or(eq(stickerPacks.id, packRef), eq(stickerPacks.slug, packRef)))
    .get();
  if (!row) throw new ApiError(404, "PACK_NOT_FOUND", "Sticker pack not found");
  const isMine = row.pack.creatorId === viewerId;
  // `removed` is a tombstone — unreachable even for the creator. Everyone else additionally needs
  // the pack to be publicly visible; a draft belongs to its creator alone.
  const reachable = row.pack.state !== "removed"
    && (isMine || PUBLIC_PACK_STATES.includes(row.pack.state as (typeof PUBLIC_PACK_STATES)[number]));
  if (!reachable) throw new ApiError(404, "PACK_NOT_FOUND", "Sticker pack not found");
  const [members, installed] = await Promise.all([
    loadPackMembers(db, [row.pack.id]),
    loadInstalledPackIds(db, viewerId, [row.pack.id]),
  ]);
  const packStickers = members.get(row.pack.id) ?? [];
  return {
    ...serializePackSummary(row, {
      viewerId,
      installed: installed.has(row.pack.id),
      coverStickers: packStickers.slice(0, COVER_STICKER_COUNT),
    }),
    stickers: packStickers.map(serializeStickerSummary),
  };
}

// ---------------------------------------------------------------------------
// Authoring
// ---------------------------------------------------------------------------

async function requireOwnPack(db: Database, creatorId: string, packId: string): Promise<StickerPackRow> {
  const pack = await db.select().from(stickerPacks)
    .where(and(eq(stickerPacks.id, packId), eq(stickerPacks.creatorId, creatorId)))
    .get();
  if (!pack || pack.state === "removed") throw new ApiError(404, "PACK_NOT_FOUND", "Sticker pack not found");
  return pack;
}

function slugifyTitle(title: string): string {
  const base = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
  return `${base.length >= 2 ? base : "pack"}-${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}`;
}

/**
 * Every sticker id must be one the creator owns *and* has published — an unpublished sticker has
 * no system rendition, so it would be invisible in every surface that matters.
 */
async function assertPublishableStickers(db: Database, creatorId: string, stickerIds: string[]): Promise<void> {
  if (stickerIds.length === 0) return;
  const rows = await db.select({ id: stickers.id, status: stickers.status, ownerId: stickers.ownerId })
    .from(stickers)
    .where(and(inArray(stickers.id, stickerIds), isNull(stickers.deletedAt)));
  const byId = new Map(rows.map((row) => [row.id, row]));
  for (const stickerId of stickerIds) {
    const row = byId.get(stickerId);
    if (!row || row.ownerId !== creatorId) {
      throw new ApiError(422, "PACK_STICKER_NOT_OWNED", "A pack may only contain stickers you own");
    }
    if (row.status !== "published") {
      throw new ApiError(422, "PACK_STICKER_NOT_PUBLISHED", "Publish a sticker before adding it to a pack");
    }
  }
}

export async function createPack(
  db: Database,
  creatorId: string,
  request: { title: string; summary?: string | null; stickerIds?: string[]; state?: "draft" | "published" },
): Promise<PackDetailV1> {
  const stickerIds = [...new Set(request.stickerIds ?? [])];
  if (stickerIds.length > MAX_PACK_ITEMS) {
    throw new ApiError(422, "PACK_TOO_LARGE", `A pack may contain at most ${MAX_PACK_ITEMS} stickers`);
  }
  await assertPublishableStickers(db, creatorId, stickerIds);
  await ensureCreatorProfile(db, creatorId);

  const wantsPublish = request.state === "published";
  if (wantsPublish && stickerIds.length === 0) {
    throw new ApiError(409, "PACK_EMPTY", "Add at least one published sticker before publishing a pack");
  }

  const packId = crypto.randomUUID();
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.insert(stickerPacks).values({
      id: packId,
      creatorId,
      slug: slugifyTitle(request.title),
      title: request.title,
      summary: request.summary ?? null,
      state: wantsPublish ? "published" : "draft",
      coverStickerId: stickerIds[0] ?? null,
      publishedAt: wantsPublish ? now : null,
      createdAt: now,
      updatedAt: now,
    });
    for (const [position, stickerId] of stickerIds.entries()) {
      await tx.insert(stickerPackItems).values({ packId, stickerId, position, addedAt: now });
    }
  });
  return getPack(db, creatorId, packId);
}

export async function updatePack(
  db: Database,
  creatorId: string,
  packId: string,
  request: { title?: string; summary?: string | null; coverStickerId?: string | null },
): Promise<PackDetailV1> {
  await requireOwnPack(db, creatorId, packId);
  if (request.coverStickerId) {
    await assertPublishableStickers(db, creatorId, [request.coverStickerId]);
  }
  // The slug is deliberately not recomputed from a new title: it is the public link, and a rename
  // must never break a URL somebody already shared.
  await db.update(stickerPacks).set({
    ...(request.title !== undefined ? { title: request.title } : {}),
    ...(request.summary !== undefined ? { summary: request.summary } : {}),
    ...(request.coverStickerId !== undefined ? { coverStickerId: request.coverStickerId } : {}),
    updatedAt: new Date(),
  }).where(eq(stickerPacks.id, packId));
  return getPack(db, creatorId, packId);
}

export async function publishPack(db: Database, creatorId: string, packId: string): Promise<PackDetailV1> {
  const pack = await requireOwnPack(db, creatorId, packId);
  const members = await loadPackMembers(db, [packId]);
  if ((members.get(packId) ?? []).length === 0) {
    throw new ApiError(409, "PACK_EMPTY", "A pack needs at least one published sticker before it can go live");
  }
  await ensureCreatorProfile(db, creatorId);
  await db.update(stickerPacks).set({
    state: "published",
    publishedAt: pack.publishedAt ?? new Date(),
    updatedAt: new Date(),
  }).where(eq(stickerPacks.id, packId));
  return getPack(db, creatorId, packId);
}

export async function unpublishPack(
  db: Database,
  creatorId: string,
  packId: string,
  state: "draft" | "unlisted" = "draft",
): Promise<PackDetailV1> {
  await requireOwnPack(db, creatorId, packId);
  await db.update(stickerPacks).set({ state, updatedAt: new Date() }).where(eq(stickerPacks.id, packId));
  return getPack(db, creatorId, packId);
}

/**
 * Tombstone the pack rather than deleting the row.
 *
 * Hard-deleting would cascade `pack_installs` without firing the counter triggers, and it would
 * strand any future purchase record. `removed` is invisible to every read path.
 */
export async function deletePack(db: Database, creatorId: string, packId: string) {
  await requireOwnPack(db, creatorId, packId);
  await db.transaction(async (tx) => {
    await tx.update(packInstalls)
      .set({ state: "uninstalled", uninstalledAt: new Date() })
      .where(and(eq(packInstalls.packId, packId), eq(packInstalls.state, "installed")));
    await tx.update(stickerPacks)
      .set({ state: "removed", updatedAt: new Date() })
      .where(eq(stickerPacks.id, packId));
  });
  return { packId };
}

export async function addPackItem(
  db: Database,
  creatorId: string,
  packId: string,
  stickerId: string,
  position?: number,
): Promise<PackDetailV1> {
  const pack = await requireOwnPack(db, creatorId, packId);
  await assertPublishableStickers(db, creatorId, [stickerId]);
  const existing = await db.select({ stickerId: stickerPackItems.stickerId }).from(stickerPackItems)
    .where(eq(stickerPackItems.packId, packId));
  if (existing.some((row) => row.stickerId === stickerId)) return getPack(db, creatorId, packId);
  if (existing.length >= MAX_PACK_ITEMS) {
    throw new ApiError(422, "PACK_TOO_LARGE", `A pack may contain at most ${MAX_PACK_ITEMS} stickers`);
  }
  await db.insert(stickerPackItems).values({
    packId,
    stickerId,
    position: position ?? existing.length,
    addedAt: new Date(),
  });
  if (!pack.coverStickerId) {
    await db.update(stickerPacks).set({ coverStickerId: stickerId }).where(eq(stickerPacks.id, packId));
  }
  return getPack(db, creatorId, packId);
}

export async function removePackItem(
  db: Database,
  creatorId: string,
  packId: string,
  stickerId: string,
): Promise<PackDetailV1> {
  const pack = await requireOwnPack(db, creatorId, packId);
  await db.delete(stickerPackItems)
    .where(and(eq(stickerPackItems.packId, packId), eq(stickerPackItems.stickerId, stickerId)));
  if (pack.coverStickerId === stickerId) {
    const next = await db.select({ stickerId: stickerPackItems.stickerId }).from(stickerPackItems)
      .where(eq(stickerPackItems.packId, packId))
      .orderBy(asc(stickerPackItems.position))
      .get();
    await db.update(stickerPacks)
      .set({ coverStickerId: next?.stickerId ?? null, updatedAt: new Date() })
      .where(eq(stickerPacks.id, packId));
  }
  return getPack(db, creatorId, packId);
}

/** Replace the pack's membership wholesale, in the order given. */
export async function reorderPackItems(
  db: Database,
  creatorId: string,
  packId: string,
  stickerIds: string[],
): Promise<PackDetailV1> {
  await requireOwnPack(db, creatorId, packId);
  const ordered = [...new Set(stickerIds)];
  if (ordered.length > MAX_PACK_ITEMS) {
    throw new ApiError(422, "PACK_TOO_LARGE", `A pack may contain at most ${MAX_PACK_ITEMS} stickers`);
  }
  await assertPublishableStickers(db, creatorId, ordered);
  const now = new Date();
  await db.transaction(async (tx) => {
    await tx.delete(stickerPackItems).where(eq(stickerPackItems.packId, packId));
    for (const [position, stickerId] of ordered.entries()) {
      await tx.insert(stickerPackItems).values({ packId, stickerId, position, addedAt: now });
    }
    await tx.update(stickerPacks)
      .set({ coverStickerId: ordered[0] ?? null, updatedAt: now })
      .where(eq(stickerPacks.id, packId));
  });
  return getPack(db, creatorId, packId);
}

// ---------------------------------------------------------------------------
// Installs
// ---------------------------------------------------------------------------

export async function installPack(db: Database, userId: string, packRef: string) {
  const pack = await db.select().from(stickerPacks)
    .where(or(eq(stickerPacks.id, packRef), eq(stickerPacks.slug, packRef)))
    .get();
  if (!pack || !PUBLIC_PACK_STATES.includes(pack.state as (typeof PUBLIC_PACK_STATES)[number])) {
    throw new ApiError(404, "PACK_NOT_FOUND", "Sticker pack not found");
  }
  // Self-install would duplicate every one of the creator's own stickers under a second section in
  // the Library and the Messages grid, and would let them inflate their own install count.
  if (pack.creatorId === userId) {
    throw new ApiError(409, "PACK_SELF_INSTALL", "Your own stickers already appear in your library");
  }

  const already = await db.select({ packId: packInstalls.packId }).from(packInstalls)
    .where(and(eq(packInstalls.userId, userId), eq(packInstalls.packId, pack.id), eq(packInstalls.state, "installed")))
    .get();
  if (already) return { packId: pack.id, installed: true as const };

  const installedCount = await db.select({ value: count() }).from(packInstalls)
    .where(and(eq(packInstalls.userId, userId), eq(packInstalls.state, "installed")))
    .get();
  if ((installedCount?.value ?? 0) >= MAX_INSTALLED_PACKS) {
    throw new ApiError(409, "TOO_MANY_INSTALLED_PACKS", `You can keep at most ${MAX_INSTALLED_PACKS} packs installed`);
  }

  // Upsert rather than insert: uninstall leaves the row behind, and the counter trigger only fires
  // on a real state change, so reinstalling never double counts.
  await db.insert(packInstalls)
    .values({
      packId: pack.id,
      userId,
      state: "installed",
      position: installedCount?.value ?? 0,
      installedAt: new Date(),
    })
    .onConflictDoUpdate({
      target: [packInstalls.packId, packInstalls.userId],
      set: { state: "installed", installedAt: new Date(), uninstalledAt: null },
    });
  return { packId: pack.id, installed: true as const };
}

export async function uninstallPack(db: Database, userId: string, packRef: string) {
  const pack = await db.select({ id: stickerPacks.id }).from(stickerPacks)
    .where(or(eq(stickerPacks.id, packRef), eq(stickerPacks.slug, packRef)))
    .get();
  if (!pack) throw new ApiError(404, "PACK_NOT_FOUND", "Sticker pack not found");
  await db.update(packInstalls)
    .set({ state: "uninstalled", uninstalledAt: new Date() })
    .where(and(
      eq(packInstalls.packId, pack.id),
      eq(packInstalls.userId, userId),
      eq(packInstalls.state, "installed"),
    ));
  return { packId: pack.id, installed: false as const };
}

export async function listInstalledPacks(db: Database, userId: string): Promise<PackSummaryV1[]> {
  const rows = await db.select({ pack: stickerPacks, profile: creatorProfiles, user: users })
    .from(packInstalls)
    .innerJoin(stickerPacks, eq(stickerPacks.id, packInstalls.packId))
    .innerJoin(users, eq(users.id, stickerPacks.creatorId))
    .leftJoin(creatorProfiles, eq(creatorProfiles.userId, stickerPacks.creatorId))
    .where(and(
      eq(packInstalls.userId, userId),
      eq(packInstalls.state, "installed"),
      inArray(stickerPacks.state, [...PUBLIC_PACK_STATES]),
    ))
    .orderBy(asc(packInstalls.position), asc(packInstalls.installedAt))
    .limit(MAX_INSTALLED_PACKS);
  const members = await loadPackMembers(db, rows.map((row) => row.pack.id), { perPack: COVER_STICKER_COUNT });
  return rows.map((row) => serializePackSummary(row, {
    viewerId: userId,
    installed: true,
    coverStickers: members.get(row.pack.id) ?? [],
  }));
}

// ---------------------------------------------------------------------------
// The sectioned library
// ---------------------------------------------------------------------------

export interface LibrarySectionV1 {
  id: string;
  kind: "mine" | "pack";
  title: string;
  packId: string | null;
  packSlug: string | null;
  creator: CreatorV1 | null;
  installedAt: string | null;
  updatedAt: string;
  stickers: ReturnType<typeof serializeStickerSummary>[];
}

/**
 * "My Stickers" plus one section per installed pack — the shape both the Library tab and the
 * Messages grid render.
 *
 * Sections are never paginated. The Messages extension reconciles its on-disk cache by removing
 * everything the response did not mention, so a pack split across a page boundary would look like
 * a pack that lost half its stickers. Bounding by `MAX_INSTALLED_PACKS` x `MAX_PACK_ITEMS` keeps
 * one response cheap enough that pagination buys nothing.
 */
export async function listLibrarySections(
  db: Database,
  userId: string,
  options: { status?: "published" | "all"; query?: string | null } = {},
): Promise<{ sections: LibrarySectionV1[]; generatedAt: string }> {
  const status = options.status ?? "published";
  const query = options.query?.trim();
  const mine = await listStickers(db, userId, {
    limit: 100,
    status: status === "all" ? undefined : "published",
    query,
  });

  const installed = await db.select({ pack: stickerPacks, profile: creatorProfiles, user: users, install: packInstalls })
    .from(packInstalls)
    .innerJoin(stickerPacks, eq(stickerPacks.id, packInstalls.packId))
    .innerJoin(users, eq(users.id, stickerPacks.creatorId))
    .leftJoin(creatorProfiles, eq(creatorProfiles.userId, stickerPacks.creatorId))
    .where(and(
      eq(packInstalls.userId, userId),
      eq(packInstalls.state, "installed"),
      inArray(stickerPacks.state, [...PUBLIC_PACK_STATES]),
    ))
    .orderBy(asc(packInstalls.position), asc(packInstalls.installedAt))
    .limit(MAX_INSTALLED_PACKS);

  // A separate members query, so a pack whose every member fell back to `draft` still yields a
  // section with an empty sticker list rather than silently disappearing from the user's library.
  const members = await loadPackMembers(db, installed.map((row) => row.pack.id), { query });

  const latest = (rows: { updatedAt: string }[], fallback: string) =>
    rows.reduce((newest, row) => (row.updatedAt > newest ? row.updatedAt : newest), fallback);

  const mineSection: LibrarySectionV1 = {
    id: "mine",
    kind: "mine",
    title: "My Stickers",
    packId: null,
    packSlug: null,
    creator: null,
    installedAt: null,
    updatedAt: latest(mine.data, new Date(0).toISOString()),
    stickers: mine.data,
  };

  const packSections = installed.map((row): LibrarySectionV1 => {
    const packStickers = (members.get(row.pack.id) ?? []).map(serializeStickerSummary);
    return {
      id: `pack:${row.pack.id}`,
      kind: "pack",
      title: row.pack.title,
      packId: row.pack.id,
      packSlug: row.pack.slug,
      creator: serializeCreator(row, { viewerId: userId }),
      installedAt: row.install.installedAt.toISOString(),
      updatedAt: latest(packStickers, row.pack.updatedAt.toISOString()),
      stickers: packStickers,
    };
  }).filter((section) => !query || section.stickers.length > 0);

  return { sections: [mineSection, ...packSections], generatedAt: new Date().toISOString() };
}

// ---------------------------------------------------------------------------
// Maintenance
// ---------------------------------------------------------------------------

/**
 * Reconcile the denormalized counters against the rows they summarize.
 *
 * SQLite does not fire row triggers for rows removed by a foreign-key `ON DELETE CASCADE` unless
 * `PRAGMA recursive_triggers` is on, so a cascading delete can leave `install_count` high. Nothing
 * hard-deletes users today; this exists so that stays a repairable bug rather than a permanent one.
 * `install_total` is intentionally left alone — it is a lifetime tally, not a summary of live rows.
 */
export async function recomputePackCounters(db: Database, packId?: string): Promise<void> {
  const scope = packId ? eq(stickerPacks.id, packId) : undefined;
  await db.update(stickerPacks).set({
    installCount: sql`(SELECT COUNT(*) FROM pack_installs WHERE pack_installs.pack_id = ${stickerPacks.id} AND pack_installs.state = 'installed')`,
    itemCount: sql`(SELECT COUNT(*) FROM sticker_pack_items WHERE sticker_pack_items.pack_id = ${stickerPacks.id})`,
  }).where(scope);
}

/** Members of a creator's pack that installers cannot see, so the edit page can say why. */
export async function listHiddenPackMembers(db: Database, creatorId: string, packId: string) {
  await requireOwnPack(db, creatorId, packId);
  const visible = await loadPackMembers(db, [packId]);
  const visibleIds = new Set((visible.get(packId) ?? []).map((row) => row.sticker.id));
  const all = await db.select({ sticker: stickers })
    .from(stickerPackItems)
    .innerJoin(stickers, eq(stickers.id, stickerPackItems.stickerId))
    .where(eq(stickerPackItems.packId, packId))
    .orderBy(asc(stickerPackItems.position));
  return all
    .filter((row) => !visibleIds.has(row.sticker.id))
    .map((row) => ({ id: row.sticker.id, title: row.sticker.title, status: row.sticker.status }));
}
