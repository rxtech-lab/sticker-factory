import { and, desc, eq, inArray } from "drizzle-orm";
import {
  ATTACHMENT_RENDITION_DIMENSIONS,
  type PublishExportsRequest,
} from "@/lib/contracts/api";
import {
  MAX_RENDITION_SECONDS,
  SHARING_APNG_DIMENSIONS,
  StickerDocumentSchema,
  type StickerDocument,
} from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { describeError, traceEvent } from "@/lib/observability/trace";
import { referencedAssetIds } from "@/lib/render/sticker-render";
import type { RenderAssets } from "@/lib/render/document-svg";
import { renderAnimatedWebp, renderApng, renderStillPng, renderStillWebp } from "@/lib/render/renditions";
import { derivedAssetId, validateImageForKind } from "@/lib/services/assets";
import { acceptRevision, bindExports } from "@/lib/services/stickers";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";

/**
 * Publishes a sticker without the client rendering anything.
 *
 * The ordinary publish is client-driven: the iOS app renders the whole export ladder, uploads it,
 * and `POST /stickers/{id}/exports` binds the asset ids. That is the right division of labour for
 * the main app, which already has the renderer on screen — but the Messages extension does not have
 * it and cannot afford to, so a sticker created there would sit as a draft until someone opened the
 * app. Quick mode is the answer: the server draws the same renditions and binds them itself, and a
 * sticker made inside Messages is sendable from Messages.
 *
 * Everything below funnels into the *same* `bindExports` the app's publish uses. Nothing here is a
 * relaxed path: the renditions are validated by `validateImageForKind` exactly as an upload is, and
 * the frame grids are checked by `validateAnimatedRenditionTiming` exactly as the app's are. What
 * differs is only who held the pen.
 */

/** Apple's ceiling for a sticker Messages will carry. */
const SYSTEM_BYTE_CEILING = 500_000;

/** The rungs the system rendition may be drawn at, largest first. Mirrors `SystemStickerSize`. */
const SYSTEM_DIMENSIONS = [618, 408, 300] as const;

/**
 * Frame rates the system ladder may fall back to, in order.
 *
 * The floor is 4 because `validateAnimatedRenditionTiming` admits nothing lower for a system
 * rendition — a long cycle of dense art is better shipped choppy than shipped as a still.
 */
const SYSTEM_FPS_LADDER = [24, 15, 12, 8, 6, 4] as const;

/** The sharing rendition's preferred size. Smaller rungs exist for artwork that will not fit. */
const SHARING_DIMENSIONS = SHARING_APNG_DIMENSIONS.filter((size) => size <= 618);

export class QuickPublishUnsupportedError extends ApiError {
  constructor(message: string) {
    super(422, "QUICK_PUBLISH_UNSUPPORTED", message);
  }
}

/**
 * Documents this renderer refuses rather than publishes wrongly.
 *
 * A rejection here is not a failure of the sticker — the app can still publish it — so the message
 * is written to be shown to someone standing in Messages, and the extension offers the main app.
 */
function assertPublishable(document: StickerDocument): void {
  if (document.kind !== "animated") return;
  if (document.fps > 30) {
    throw new QuickPublishUnsupportedError(
      "This animation runs above 30 frames per second, which Messages stickers cannot carry. Publish it in the main app.",
    );
  }
  const playbackSeconds = document.durationSeconds / Math.max(document.speed, 0.0001);
  const cycleSeconds = playbackSeconds * (document.loop === "pingPong" ? 2 : 1);
  const total = cycleSeconds + (document.loop === "once" ? 0 : 0.6);
  if (total < 0.5 || total > MAX_RENDITION_SECONDS) {
    throw new QuickPublishUnsupportedError(
      `This animation is ${total.toFixed(1)} seconds long; a sticker has to be between 0.5 and ${MAX_RENDITION_SECONDS} seconds. Publish it in the main app.`,
    );
  }
}

/** Every referenced asset's bytes, keyed by id. A missing one draws as the renderer's placeholder. */
async function loadDocumentAssets(
  db: Database,
  ownerId: string,
  document: StickerDocument,
): Promise<RenderAssets> {
  const ids = referencedAssetIds(document);
  const loaded: RenderAssets = new Map();
  if (ids.length === 0) return loaded;
  const rows = await db.select().from(assets)
    .where(and(eq(assets.ownerId, ownerId), inArray(assets.id, ids)));
  const store = getObjectStore();
  await Promise.all(rows.filter((asset) => asset.state === "ready").map(async (asset) => {
    try {
      const object = await store.get(asset.r2Key);
      loaded.set(asset.id, { bytes: object.bytes, mimeType: asset.mimeType });
    } catch (error) {
      traceEvent("quickPublish:asset:unreadable", { assetId: asset.id, error: describeError(error) });
    }
  }));
  const missing = ids.filter((id) => !loaded.has(id));
  if (missing.length > 0) {
    // Refused rather than drawn: the agent's contact sheet can afford a placeholder because it is a
    // review render, but a placeholder published as a sticker is a purple box the user has to
    // discover in a conversation.
    throw new QuickPublishUnsupportedError("Some of this sticker's artwork is missing. Publish it in the main app.");
  }
  return loaded;
}

/**
 * Writes one rendered rendition into the object store and mints its asset row.
 *
 * The id is derived from (revision, slot) rather than random so the whole publish is idempotent: a
 * workflow replay, or a second Publish press, rewrites the same object and re-binds the same ids
 * instead of orphaning a set of renditions in R2 on every attempt.
 */
/** Which container each rendition kind is written in. */
const RENDITION_MIME = {
  master: "image/png",
  apng: "image/png",
  system: "image/png",
  attachment: "image/png",
  webp: "image/webp",
} as const;

async function storeRendition(
  db: Database,
  ownerId: string,
  stickerId: string,
  revisionId: string,
  slot: string,
  kind: keyof typeof RENDITION_MIME,
  bytes: Uint8Array,
): Promise<string> {
  const id = derivedAssetId(revisionId, slot);
  const inspection = await inspectImage(bytes);
  const mimeType = RENDITION_MIME[kind];
  const r2Key = objectKey(ownerId, id, mimeType);
  const row = {
    id,
    ownerId,
    stickerId,
    kind,
    state: "ready" as const,
    r2Key,
    mimeType,
    byteSize: inspection.byteSize,
    width: inspection.width,
    height: inspection.height,
    frameCount: inspection.frameCount,
    durationSeconds: inspection.durationSeconds,
    fps: inspection.fps,
    sha256: inspection.sha256,
    hasAlpha: inspection.hasAlpha,
    originalFilename: `quick-${slot}.${mimeType === "image/webp" ? "webp" : "png"}`,
    createdAt: new Date(),
    readyAt: new Date(),
  };
  // The same gate an upload passes. A rendition this renderer got wrong is caught here, next to the
  // code that drew it, rather than three calls later as an opaque 422 from `bindExports`.
  validateImageForKind(row as unknown as typeof assets.$inferSelect, inspection);
  await getObjectStore().put(r2Key, {
    bytes,
    contentType: mimeType,
    metadata: { sha256: inspection.sha256 },
  });
  await db.insert(assets).values(row).onConflictDoUpdate({ target: assets.id, set: {
    kind: row.kind,
    state: row.state,
    r2Key: row.r2Key,
    mimeType: row.mimeType,
    byteSize: row.byteSize,
    width: row.width,
    height: row.height,
    frameCount: row.frameCount,
    durationSeconds: row.durationSeconds,
    fps: row.fps,
    sha256: row.sha256,
    hasAlpha: row.hasAlpha,
    readyAt: row.readyAt,
  } });
  return id;
}

/**
 * The largest rung of `sizes` whose render lands under `ceiling`, or the smallest rung if none do.
 *
 * Returning the smallest rather than throwing keeps the decision with the caller: only the system
 * rendition has a ceiling it must respect, and it has a second lever — frame rate — to try before
 * giving up.
 */
async function ladder(
  sizes: readonly number[],
  ceiling: number,
  draw: (size: number) => Promise<Uint8Array>,
): Promise<{ bytes: Uint8Array; size: number; fits: boolean }> {
  let last: { bytes: Uint8Array; size: number } | undefined;
  for (const size of sizes) {
    const bytes = await draw(size);
    last = { bytes, size };
    if (bytes.byteLength < ceiling) return { bytes, size, fits: true };
  }
  return { ...last!, fits: false };
}

/**
 * One line of the publish's own progress.
 *
 * Rendering the export ladder is the slowest half of a quick-mode create — four to seven full
 * rasterisations, and for an animation every frame of each — and until this existed the surface
 * watching it had a spinner and nothing else for the whole of it. The `id` is deliberately in the
 * same snake_case vocabulary the generation tools use (`StickerToolLabel` on the client), so a
 * publish step draws through exactly the same list as the steps that drew the artwork.
 */
export interface QuickPublishStep {
  id: string;
  status: "streaming" | "complete";
  /** The publish's own 0…1 as of this line. */
  progress: number;
}

export type QuickPublishReporter = (step: QuickPublishStep) => Promise<void>;

/** Announces a step, runs it, and announces it done. */
async function tracked<T>(
  report: QuickPublishReporter,
  id: string,
  from: number,
  to: number,
  work: () => Promise<T>,
): Promise<T> {
  await report({ id, status: "streaming", progress: from });
  const value = await work();
  await report({ id, status: "complete", progress: to });
  return value;
}

interface RenderedExports {
  request: Omit<PublishExportsRequest, "revisionId">;
}

async function renderStaticExports(
  db: Database,
  ownerId: string,
  stickerId: string,
  revisionId: string,
  document: StickerDocument,
  sourceAssets: RenderAssets,
  report: QuickPublishReporter,
): Promise<RenderedExports> {
  // 1024 square is what `validateImageForKind` demands of a master, and it is the size the app
  // uploads, so the library thumbnail and the share sheet get the same pixels either way.
  const master = await tracked(report, "render_artwork", 0.05, 0.35, () => (
    renderStillPng(document, sourceAssets, 1_024)
  ));
  const attachments = await tracked(report, "render_attachments", 0.35, 0.55, () => Promise.all(
    ([["medium", ATTACHMENT_RENDITION_DIMENSIONS.medium], ["small", ATTACHMENT_RENDITION_DIMENSIONS.small]] as const)
      .map(async ([slot, size]) => [slot, await renderStillPng(document, sourceAssets, size)] as const),
  ));
  // The same 1024 px frame as the master, in the container WinkySticker prefers to attach. Drawn
  // rather than converted, because the renderer is right here and a re-raster costs less than
  // decoding the PNG back out again.
  const webp = await tracked(report, "render_webp", 0.55, 0.62, () => (
    renderStillWebp(document, sourceAssets, 1_024)
  ));
  // Quantised: a still rendition carries one palette, so indexing it is free size and it is what
  // keeps dense artwork under Apple's ceiling at the largest rung.
  const system = await tracked(report, "render_sizes", 0.62, 0.8, () => (
    ladder(SYSTEM_DIMENSIONS, SYSTEM_BYTE_CEILING, (size) => (
      renderStillPng(document, sourceAssets, size, { palette: true })
    ))
  ));
  if (!system.fits) {
    throw new QuickPublishUnsupportedError("This sticker is too detailed to fit Messages' size limit. Publish it in the main app.");
  }

  const [pngAssetId, systemAssetId, attachmentMediumAssetId, attachmentSmallAssetId, webpAssetId] = await tracked(
    report,
    "save_renditions",
    0.8,
    0.95,
    () => Promise.all([
      storeRendition(db, ownerId, stickerId, revisionId, "master", "master", master),
      storeRendition(db, ownerId, stickerId, revisionId, "system", "system", system.bytes),
      storeRendition(db, ownerId, stickerId, revisionId, "attachment-medium", "attachment", attachments[0][1]),
      storeRendition(db, ownerId, stickerId, revisionId, "attachment-small", "attachment", attachments[1][1]),
      storeRendition(db, ownerId, stickerId, revisionId, "webp", "webp", webp),
    ]),
  );
  return { request: { pngAssetId, systemAssetId, attachmentMediumAssetId, attachmentSmallAssetId, webpAssetId } };
}

async function renderAnimatedExports(
  db: Database,
  ownerId: string,
  stickerId: string,
  revisionId: string,
  document: Extract<StickerDocument, { kind: "animated" }>,
  sourceAssets: RenderAssets,
  report: QuickPublishReporter,
): Promise<RenderedExports> {
  // The sharing rendition and the two attachment copies are rendered on the document's own grid:
  // their frame counts are checked exactly, so unlike the system sticker they never trade frame
  // rate away. Their only ceiling is the 25 MB upload bound, which `SHARING_DIMENSIONS` walks.
  const sharing = await tracked(report, "render_frames", 0.05, 0.4, () => (
    ladder(SHARING_DIMENSIONS, 25 * 1024 * 1024, async (size) => (
      (await renderApng(document, sourceAssets, size, document.fps)).bytes
    ))
  ));
  const [attachmentMedium, attachmentSmall] = await tracked(report, "render_attachments", 0.4, 0.55, async () => [
    await renderApng(document, sourceAssets, ATTACHMENT_RENDITION_DIMENSIONS.medium, document.fps),
    await renderApng(document, sourceAssets, ATTACHMENT_RENDITION_DIMENSIONS.small, document.fps),
  ]);
  // The same cycle in the container WinkySticker prefers to attach. It walks the sharing ladder for
  // form's sake rather than need: WebP reaches the upload ceiling only on artwork the APNG above it
  // could not have fitted either, so in practice this is one render at the top rung.
  const webp = await tracked(report, "render_webp", 0.55, 0.62, () => (
    ladder(SHARING_DIMENSIONS, 25 * 1024 * 1024, async (size) => (
      (await renderAnimatedWebp(document, sourceAssets, size, document.fps)).bytes
    ))
  ));

  // Size first, then frame rate: dropping pixels costs nothing anyone sees in a 300 px transcript
  // bubble, while dropping frames is the one compromise a viewer notices.
  const system = await tracked(report, "render_sizes", 0.62, 0.85, async () => {
    for (const size of SYSTEM_DIMENSIONS) {
      for (const fps of [document.fps, ...SYSTEM_FPS_LADDER.filter((rung) => rung < document.fps)]) {
        const rendered = await renderApng(document, sourceAssets, size, fps);
        if (rendered.bytes.byteLength < SYSTEM_BYTE_CEILING) return rendered;
      }
    }
    return undefined;
  });
  if (!system) {
    // The app has one more move here — it ships the poster frame as a still system rendition and
    // keeps the motion in the sharing APNG. That path is deliberately not taken automatically:
    // quick mode publishes what the user just watched, and silently sending a still of an animation
    // they approved is worse than telling them where to go to publish it properly.
    throw new QuickPublishUnsupportedError("This animation is too detailed to fit Messages' size limit. Publish it in the main app.");
  }

  const [apngAssetId, systemAssetId, attachmentMediumAssetId, attachmentSmallAssetId, webpAssetId] = await tracked(
    report,
    "save_renditions",
    0.85,
    0.95,
    () => Promise.all([
      storeRendition(db, ownerId, stickerId, revisionId, "apng", "apng", sharing.bytes),
      storeRendition(db, ownerId, stickerId, revisionId, "system", "system", system.bytes),
      storeRendition(db, ownerId, stickerId, revisionId, "attachment-medium", "attachment", attachmentMedium.bytes),
      storeRendition(db, ownerId, stickerId, revisionId, "attachment-small", "attachment", attachmentSmall.bytes),
      storeRendition(db, ownerId, stickerId, revisionId, "webp", "webp", webp.bytes),
    ]),
  );
  return {
    request: {
      apngAssetId,
      systemAssetId,
      attachmentMediumAssetId,
      attachmentSmallAssetId,
      webpAssetId,
      mp4Background: document.mp4Background,
    },
  };
}

/**
 * A type alias rather than an interface on purpose: `completeJobStep` takes a
 * `Record<string, unknown>`, and only an alias picks up the implicit index signature that makes a
 * result assignable to one.
 */
export type QuickPublishResult = {
  stickerId: string;
  revisionId: string;
  sourceRevisionId: string;
  status: "published";
};

/**
 * Accepts whatever candidate is outstanding, renders its renditions, and binds them.
 *
 * Accepting is part of the operation rather than a separate call the extension has to make: quick
 * mode's whole premise is that looking at the sticker *is* the review, so the tap that publishes is
 * the tap that accepts. Someone who wants the candidate rejected revises instead, which supersedes
 * it.
 */
export async function quickPublishSticker(
  db: Database,
  ownerId: string,
  stickerId: string,
  /** Where the render's own progress goes. Omitted, the publish is silent but identical. */
  onProgress?: QuickPublishReporter,
  /**
   * `candidateId` publishes that candidate rather than the newest one. `acceptLast` renders it
   * before accepting it: accepting makes an unrendered revision active and drops the sticker to
   * draft, and a sticker in use — the pet's, drawn on the watch and the widget — must not vanish
   * for the whole render. A render that fails then leaves the candidate undecided.
   */
  options: { candidateId?: string; acceptLast?: boolean } = {},
): Promise<QuickPublishResult> {
  const report: QuickPublishReporter = onProgress ?? (async () => {});
  const sticker = await db.select().from(stickers)
    .where(and(eq(stickers.id, stickerId), eq(stickers.ownerId, ownerId))).then(firstRow);
  if (!sticker || sticker.deletedAt) throw new ApiError(404, "STICKER_NOT_FOUND", "Sticker not found");

  const candidate = await db.select().from(stickerRevisions).where(and(
    eq(stickerRevisions.stickerId, stickerId),
    eq(stickerRevisions.candidateState, "candidate"),
    ...(options.candidateId ? [eq(stickerRevisions.id, options.candidateId)] : []),
  )).orderBy(desc(stickerRevisions.createdAt)).then(firstRow);

  if (!candidate && options.candidateId) {
    // Gone from the candidates is fine only for a replay that already accepted it; a rejected or
    // superseded one must not quietly republish whatever is active instead.
    const named = await db.select({ candidateState: stickerRevisions.candidateState }).from(stickerRevisions)
      .where(and(eq(stickerRevisions.id, options.candidateId), eq(stickerRevisions.stickerId, stickerId))).then(firstRow);
    if (named?.candidateState !== "accepted") {
      throw new ApiError(409, "REVISION_ALREADY_DECIDED", "Revision is missing or no longer a candidate");
    }
  }
  if (candidate && !options.acceptLast) await acceptRevision(db, ownerId, stickerId, candidate.id);

  const targetId = candidate?.id ?? sticker.activeRevisionId;
  if (!targetId) throw new ApiError(409, "NO_REVISION_TO_PUBLISH", "This sticker has nothing to publish yet");
  const revision = await db.select().from(stickerRevisions)
    .where(and(eq(stickerRevisions.id, targetId), eq(stickerRevisions.stickerId, stickerId))).then(firstRow);
  if (!revision) throw new ApiError(409, "NO_REVISION_TO_PUBLISH", "This sticker has nothing to publish yet");

  // Already carrying its renditions — a replayed step, or a second press. `bindExports` is
  // idempotent on the derived id, but re-rendering to find that out would cost the whole ladder.
  if (revision.systemAssetId && sticker.status === "published") {
    return { stickerId, revisionId: revision.id, sourceRevisionId: revision.parentRevisionId ?? revision.id, status: "published" };
  }

  const document = StickerDocumentSchema.parse(revision.documentJson);
  assertPublishable(document);
  const sourceAssets = await loadDocumentAssets(db, ownerId, document);

  const startedAt = Date.now();
  const { request } = document.kind === "animated"
    ? await renderAnimatedExports(db, ownerId, stickerId, revision.id, document, sourceAssets, report)
    : await renderStaticExports(db, ownerId, stickerId, revision.id, document, sourceAssets, report);
  traceEvent("quickPublish:rendered", { stickerId, revisionId: revision.id, kind: document.kind, ms: Date.now() - startedAt });

  if (candidate && options.acceptLast) await acceptRevision(db, ownerId, stickerId, candidate.id);
  return bindExports(
    db,
    ownerId,
    stickerId,
    { ...request, revisionId: revision.id } as PublishExportsRequest,
    // Deterministic, so the published revision a retry produces is the one the first attempt made
    // rather than a second row forking the chain.
    derivedAssetId(revision.id, "published-revision"),
  );
}
