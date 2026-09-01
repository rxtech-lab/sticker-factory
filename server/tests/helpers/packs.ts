import { eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { getObjectStore, objectKey } from "@/lib/storage/r2";

/**
 * A sticker in the state the marketplace actually requires: `published`, with an active revision
 * that carries a ready `system` rendition.
 *
 * The real path there runs through the generation workflow and an export job, which is far more
 * machinery than a pack test needs — so the rows are written directly, but in exactly the shape
 * `loadPackMembers` and `isPackPublishedAsset` join against.
 */
export async function seedPublishedSticker(
  db: Database,
  ownerId: string,
  options: { title?: string; kind?: "static" | "animated"; attachments?: boolean } = {},
) {
  const stickerId = crypto.randomUUID();
  const systemAssetId = crypto.randomUUID();
  const pngAssetId = crypto.randomUUID();
  const attachmentMediumAssetId = crypto.randomUUID();
  const attachmentSmallAssetId = crypto.randomUUID();
  const revisionId = crypto.randomUUID();
  const now = new Date();

  await db.insert(stickers).values({
    id: stickerId,
    ownerId,
    title: options.title ?? "Seeded",
    kind: options.kind ?? "static",
    status: "published",
    createdAt: now,
    updatedAt: now,
  });

  const store = getObjectStore();
  const seeded: [string, "system" | "master" | "attachment", number][] = [
    [systemAssetId, "system", 408],
    [pngAssetId, "master", 1024],
  ];
  if (options.attachments) {
    seeded.push([attachmentMediumAssetId, "attachment", 408], [attachmentSmallAssetId, "attachment", 300]);
  }
  for (const [id, kind, dimension] of seeded) {
    const r2Key = objectKey(ownerId, id, "image/png");
    // Signing a download re-checks that the object exists, so the bytes have to be there too.
    await store.put(r2Key, { bytes: Buffer.from(`${kind}:${id}`), contentType: "image/png" });
    await db.insert(assets).values({
      id,
      ownerId,
      stickerId,
      kind,
      state: "ready",
      r2Key,
      mimeType: "image/png",
      byteSize: 4096,
      width: dimension,
      height: dimension,
      frameCount: 1,
      sha256: id.replace(/-/g, "").padEnd(64, "0"),
      hasAlpha: true,
      originalFilename: `${kind}-secret-name.png`,
      createdAt: now,
      readyAt: now,
    });
  }

  await db.insert(stickerRevisions).values({
    id: revisionId,
    stickerId,
    kind: options.kind ?? "static",
    candidateState: "accepted",
    documentJson: {
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers: [],
    } as never,
    masterAssetId: pngAssetId,
    pngAssetId,
    systemAssetId,
    attachmentMediumAssetId: options.attachments ? attachmentMediumAssetId : null,
    attachmentSmallAssetId: options.attachments ? attachmentSmallAssetId : null,
    createdAt: now,
    decidedAt: now,
  });
  await db.update(stickers).set({ activeRevisionId: revisionId }).where(eq(stickers.id, stickerId));

  return { stickerId, revisionId, systemAssetId, pngAssetId, attachmentMediumAssetId, attachmentSmallAssetId };
}

export async function seedUser(db: Database, id: string, displayName?: string) {
  const now = new Date();
  await db.insert(users).values({ id, displayName: displayName ?? null, createdAt: now, updatedAt: now });
}
