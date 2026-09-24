import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import fixture from "@/fixtures/sticker-document-v5.json";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { type Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers, stickerPacks, stickerPackItems, packInstalls } from "@/lib/db/schema";
import { preparePlaybackBundle, getStickerPlayback } from "@/lib/services/playback";
import { getReadableAsset } from "@/lib/services/assets";
import { getPublicPack, getPublicPackPlayback } from "@/lib/services/public-packs";
import { saveEditedRevision } from "@/lib/services/sticker-revisions";
import { listLibrarySections } from "@/lib/services/packs";
import { MemoryObjectStore, setObjectStoreForTests, objectKey, inspectImage } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("published configurable playback", () => {
  let db: Database, close: () => Promise<void>, store: MemoryObjectStore;
  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    store = new MemoryObjectStore(); setObjectStoreForTests(store);
    await seedUser(db, "owner"); await seedUser(db, "installer"); await seedUser(db, "stranger");
  });
  afterEach(async () => { await close(); setObjectStoreForTests(undefined); });

  async function source() {
    const sticker = await seedPublishedSticker(db, "owner", { kind: "animated" });
    const document = StickerDocumentSchema.parse(fixture);
    for (const id of ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]) {
      const bytes = await sharp({ create: { width: 64, height: 64, channels: 4, background: "#FF000088" } }).png().toBuffer();
      const inspection = await inspectImage(bytes), r2Key = objectKey("owner", id, "image/png");
      await store.put(r2Key, { bytes, contentType: "image/png" });
      await db.insert(assets).values({ id, ownerId: "owner", stickerId: sticker.stickerId, kind: "reference", state: "ready", r2Key,
        mimeType: "image/png", width: 64, height: 64, byteSize: bytes.length, sha256: inspection.sha256, hasAlpha: true,
        originalFilename: "private-reference-capture.png" });
    }
    return { sticker, document };
  }
  async function published() {
    const { sticker, document } = await source();
    const bundle = await preparePlaybackBundle(db, "owner", sticker.stickerId, sticker.revisionId, document);
    const revisionId = crypto.randomUUID();
    await db.insert(stickerRevisions).values({ id: revisionId, stickerId: sticker.stickerId, parentRevisionId: sticker.revisionId, kind: "animated", candidateState: "accepted", documentJson: document, playbackJson: bundle, systemAssetId: sticker.systemAssetId });
    await db.update(stickers).set({ activeRevisionId: revisionId }).where(eq(stickers.id, sticker.stickerId));
    const packId = crypto.randomUUID();
    await db.insert(stickerPacks).values({ id: packId, creatorId: "owner", slug: "controls", title: "Pets", state: "published" });
    await db.insert(stickerPackItems).values({ packId, stickerId: sticker.stickerId });
    await db.insert(packInstalls).values({ packId, userId: "installer", state: "installed" });
    return { sticker, revisionId, bundle: bundle!, packId, document };
  }
  it("serves owners and installed-pack users only, advertising the exact published revision", async () => {
    const { sticker, revisionId, bundle, packId } = await published();
    const owner = await getStickerPlayback(db, "owner", sticker.stickerId, revisionId);
    expect(await getStickerPlayback(db, "installer", sticker.stickerId, revisionId)).toEqual(owner);
    expect(owner.assets).toHaveLength(2);
    expect(JSON.stringify(owner)).not.toContain("private-reference");
    expect(JSON.stringify(owner)).not.toContain("11111111-1111-4111-8111-111111111111");
    expect(JSON.stringify(owner)).not.toContain("prompt");
    expect((await getReadableAsset(db, "installer", bundle.assetIds[0])).asset.kind).toBe("playback");
    await expect(getReadableAsset(db, "installer", "11111111-1111-4111-8111-111111111111")).rejects.toMatchObject({ status: 404 });
    await expect(getStickerPlayback(db, "stranger", sticker.stickerId)).rejects.toMatchObject({ status: 404 });
    await expect(getStickerPlayback(db, "owner", sticker.stickerId, sticker.revisionId)).rejects.toMatchObject({ status: 404 });
    const library = await listLibrarySections(db, "installer");
    expect(JSON.stringify(library)).toContain(`"playbackRevisionId":"${revisionId}"`);
    await db.update(packInstalls).set({ state: "uninstalled", uninstalledAt: new Date() }).where(eq(packInstalls.packId, packId));
    await expect(getStickerPlayback(db, "installer", sticker.stickerId)).rejects.toMatchObject({ status: 404 });
    await expect(getReadableAsset(db, "installer", bundle.assetIds[0])).rejects.toMatchObject({ status: 404 });
    expect((await getStickerPlayback(db, "owner", sticker.stickerId)).revisionId).toBe(revisionId);
  });
  it("serves shared-pack viewers the bundle with signed artwork while the pack link is live", async () => {
    const { sticker, revisionId, bundle, packId } = await published();
    expect((await getPublicPack(db, "controls")).stickers[0].playbackRevisionId).toBe(revisionId);
    const shared = await getPublicPackPlayback(db, "controls", sticker.stickerId);
    const owner = await getStickerPlayback(db, "owner", sticker.stickerId);
    expect(shared.revisionId).toBe(revisionId);
    expect(shared.document).toEqual(owner.document);
    expect(shared.assets.map(({ id }) => id)).toEqual(owner.assets.map(({ id }) => id));
    expect(shared.assets.every((asset) => asset.url.length > 0)).toBe(true);
    expect(JSON.stringify(shared)).not.toContain("private-reference");
    expect(bundle.assetIds).toHaveLength(2);
    await expect(getPublicPackPlayback(db, "controls", crypto.randomUUID())).rejects.toMatchObject({ status: 404 });
    await expect(getPublicPackPlayback(db, "missing", sticker.stickerId)).rejects.toMatchObject({ status: 404 });
    await db.update(stickerPacks).set({ state: "unlisted" }).where(eq(stickerPacks.id, packId));
    expect((await getPublicPackPlayback(db, "controls", sticker.stickerId)).revisionId).toBe(revisionId);
    await db.update(stickerPacks).set({ state: "draft" }).where(eq(stickerPacks.id, packId));
    await expect(getPublicPackPlayback(db, "controls", sticker.stickerId)).rejects.toMatchObject({ code: "PLAYBACK_NOT_FOUND" });
  });
  it("does not expose poses for stickers without a published bundle", async () => {
    const plain = await seedPublishedSticker(db, "owner");
    const packId = crypto.randomUUID();
    await db.insert(stickerPacks).values({ id: packId, creatorId: "owner", slug: "plain", title: "Plain", state: "published" });
    await db.insert(stickerPackItems).values({ packId, stickerId: plain.stickerId });
    expect((await getPublicPack(db, "plain")).stickers[0].playbackRevisionId).toBeNull();
    await expect(getPublicPackPlayback(db, "plain", plain.stickerId)).rejects.toMatchObject({ code: "PLAYBACK_NOT_FOUND" });
  });
  it("rejects incomplete bundles, unapproved source changes, and legacy destructive edits", async () => {
    const { sticker, revisionId, bundle, document } = await published();
    const changed = structuredClone(document); changed.layers[0].name = "Changed";
    await expect(preparePlaybackBundle(db, "owner", sticker.stickerId, revisionId, document, changed)).rejects.toMatchObject({ code: "PLAYBACK_REVISION_MISMATCH" });
    const legacy = { ...document, configuration: undefined };
    await expect(saveEditedRevision(db, "owner", sticker.stickerId, { parentRevisionId: revisionId, document: legacy }, crypto.randomUUID(), 4)).rejects.toMatchObject({ code: "STICKER_CLIENT_UPDATE_REQUIRED" });
    await db.update(assets).set({ state: "failed" }).where(eq(assets.id, bundle.assetIds[1]));
    await expect(getStickerPlayback(db, "owner", sticker.stickerId)).rejects.toMatchObject({ code: "PLAYBACK_INCOMPLETE" });
    await expect(db.update(stickerRevisions).set({ playbackJson: null }).where(eq(stickerRevisions.id, revisionId))).rejects.toThrow();
  });
  it("never publishes a variant whose source has not completed generation", async () => {
    const { sticker, document } = await source();
    await db.update(assets).set({ state: "failed" }).where(eq(assets.id, "22222222-2222-4222-8222-222222222222"));
    await expect(preparePlaybackBundle(db, "owner", sticker.stickerId, sticker.revisionId, document)).rejects.toThrow();
  });
});

describe("published sprite playback", () => {
  let db: Database, close: () => Promise<void>, store: MemoryObjectStore;
  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    store = new MemoryObjectStore(); setObjectStoreForTests(store);
    await seedUser(db, "owner");
  });
  afterEach(async () => { await close(); setObjectStoreForTests(undefined); });

  it("rasters every clip sheet, the expression sheet, and the poster into the bundle", async () => {
    const spriteFixture = (await import("@/fixtures/sticker-document-v5-sprite.json")).default;
    const sticker = await seedPublishedSticker(db, "owner", { kind: "animated" });
    const document = StickerDocumentSchema.parse(spriteFixture);
    const sheets = [
      { id: "31111111-1111-4111-8111-111111111111", kind: "sequence" as const, columns: 3, rows: 2, frameCount: 6 },
      { id: "32222222-2222-4222-8222-222222222222", kind: "sequence" as const, columns: 3, rows: 2, frameCount: 6 },
      { id: "33333333-3333-4333-8333-333333333333", kind: "sequence" as const, columns: 3, rows: 3, frameCount: 3 },
      { id: "34444444-4444-4444-8444-444444444444", kind: "master" as const },
    ];
    for (const sheet of sheets) {
      const bytes = await sharp({ create: { width: 96, height: 96, channels: 4, background: "#00FF0088" } }).png().toBuffer();
      const inspection = await inspectImage(bytes), r2Key = objectKey("owner", sheet.id, "image/png");
      await store.put(r2Key, { bytes, contentType: "image/png" });
      await db.insert(assets).values({ id: sheet.id, ownerId: "owner", stickerId: sticker.stickerId, kind: sheet.kind, state: "ready", r2Key,
        mimeType: "image/png", width: 96, height: 96, byteSize: bytes.length, sha256: inspection.sha256, hasAlpha: true,
        ...(sheet.kind === "sequence" ? { sequenceColumns: sheet.columns, sequenceRows: sheet.rows, frameCount: sheet.frameCount, fps: 1, durationSeconds: sheet.frameCount } : {}),
        originalFilename: `private-${sheet.id}.png` });
    }
    const bundle = (await preparePlaybackBundle(db, "owner", sticker.stickerId, sticker.revisionId, document))!;
    expect(bundle.assetIds).toHaveLength(4);
    const hero = bundle.document.layers[0];
    if (hero.type !== "sprite") throw new Error("hero should stay a sprite");
    const rewritten = [...hero.clips.map((clip) => clip.assetId), hero.expressions.assetId, hero.posterAssetId];
    expect(new Set(rewritten).size).toBe(4);
    for (const id of rewritten) expect(bundle.assetIds).toContain(id);
    for (const sheet of sheets) expect(bundle.assetIds).not.toContain(sheet.id);
    expect(JSON.stringify(bundle)).not.toContain("private-");
    // The controls survive untouched, so the client still selects a clip and a face locally.
    expect(bundle.document.configuration).toEqual(document.configuration);
    const derived = await db.select().from(assets).where(eq(assets.id, hero.clips[0].assetId));
    expect(derived[0]).toMatchObject({ kind: "playback", state: "ready", sequenceColumns: 3, sequenceRows: 2, frameCount: 6 });
  });
});
