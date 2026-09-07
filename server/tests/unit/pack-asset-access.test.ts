import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, stickerPacks, stickers } from "@/lib/db/schema";
import { createAssetDownload, createAssetPreview, getOwnedAsset } from "@/lib/services/assets";
import { createPack, publishPack, unpublishPack } from "@/lib/services/packs";
import { MemoryObjectStore, getObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

/**
 * The marketplace's one real security seam: an installer reads artwork owned by somebody else.
 *
 * Every failure below has to be a 404 rather than a 403 — telling a stranger that an asset id
 * exists but is forbidden is itself a disclosure.
 */
describe("cross-owner pack asset access", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "creator", "Mika");
    await seedUser(db, "stranger", "Sam");
  });

  afterEach(async () => {
    setObjectStoreForTests(undefined);
    await close();
  });

  it("opens published pack artwork to strangers and closes it again on every retraction", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { title: "Wave" });

    // Before any pack exists the sticker is published but private: publication means "renditions
    // exist", not "shared".
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId))
      .rejects.toMatchObject({ status: 404, code: "ASSET_NOT_FOUND" });

    const pack = await createPack(db, "creator", { title: "Cozy", stickerIds: [sticker.stickerId] });
    // A draft pack is not consent to display either.
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId))
      .rejects.toMatchObject({ status: 404 });

    await publishPack(db, "creator", pack.id);
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).resolves.toMatchObject({
      asset: { id: sticker.systemAssetId },
    });
    // No install is required: browse and pack detail must render art to people who have not
    // installed anything.
    await expect(createAssetPreview(db, "stranger", sticker.systemAssetId)).resolves.toBeDefined();

    // Exactly what a device edit does — the sticker drops to draft and its art closes again.
    await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, sticker.stickerId));
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).rejects.toMatchObject({ status: 404 });
    await db.update(stickers).set({ status: "published" }).where(eq(stickers.id, sticker.stickerId));
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).resolves.toBeDefined();

    // The soft-delete tombstone closes it too, before any bytes are purged.
    await db.update(stickers).set({ status: "deleting", deletedAt: new Date() }).where(eq(stickers.id, sticker.stickerId));
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).rejects.toMatchObject({ status: 404 });
    await db.update(stickers).set({ status: "published", deletedAt: null }).where(eq(stickers.id, sticker.stickerId));

    await unpublishPack(db, "creator", pack.id, "draft");
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).rejects.toMatchObject({ status: 404 });

    // The creator never loses access to their own asset through any of this.
    await expect(createAssetDownload(db, "creator", sticker.systemAssetId)).resolves.toBeDefined();
  });

  it("shares only artwork kinds, never the creator's inputs", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Kinds", stickerIds: [sticker.stickerId], state: "published" });
    expect(pack.state).toBe("published");

    // The master is the resolved preview asset for a static sticker, so it is shared.
    await expect(createAssetDownload(db, "stranger", sticker.pngAssetId)).resolves.toBeDefined();

    // Private inputs and the MP4 rendition stay owner-only no matter how public the pack is, and
    // they are bound to the same published sticker — so only the kind rule can be excluding them.
    for (const kind of ["reference", "mask", "mp4", "chat_attachment"] as const) {
      const id = crypto.randomUUID();
      const mimeType = kind === "mp4" ? "video/mp4" : "image/png";
      const r2Key = objectKey("creator", id, mimeType);
      await getObjectStore().put(r2Key, { bytes: Buffer.from(kind), contentType: mimeType });
      await db.insert(assets).values({
        id,
        ownerId: "creator",
        stickerId: sticker.stickerId,
        kind,
        state: "ready",
        r2Key,
        mimeType,
        byteSize: 128,
        createdAt: new Date(),
        readyAt: new Date(),
      });
      await expect(createAssetDownload(db, "stranger", id)).rejects.toMatchObject({ status: 404, code: "ASSET_NOT_FOUND" });
      await expect(createAssetDownload(db, "creator", id)).resolves.toBeDefined();
    }
  });

  /**
   * The seam the whole messenger feature rests on. Since the export sheet stopped encoding, these
   * two files are the *only* thing it can send — there is no preview to fall back to and re-render
   * — so an installer who cannot read them is offered two hand-off buttons that 404 on every
   * sticker. Nothing else in the app would catch that.
   */
  it("shares the messenger renditions with everyone who can see the pack", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { messengerRenditions: true });
    const pack = await createPack(db, "creator", {
      title: "Messengers",
      stickerIds: [sticker.stickerId],
      state: "published",
    });
    expect(pack.state).toBe("published");

    await expect(createAssetDownload(db, "stranger", sticker.whatsappAssetId)).resolves.toBeDefined();
    await expect(createAssetDownload(db, "stranger", sticker.telegramAssetId)).resolves.toBeDefined();

    // And they close again with the pack, exactly like every other shared kind.
    await unpublishPack(db, "creator", pack.id, "draft");
    for (const assetId of [sticker.whatsappAssetId, sticker.telegramAssetId]) {
      await expect(createAssetDownload(db, "stranger", assetId))
        .rejects.toMatchObject({ status: 404, code: "ASSET_NOT_FOUND" });
      await expect(createAssetDownload(db, "creator", assetId)).resolves.toBeDefined();
    }
  });

  /**
   * Being the right *kind* is not enough on its own: a rendition the revision does not point at is
   * a file that was uploaded and never bound, and it stays private.
   */
  it("keeps an unbound messenger rendition private even inside a published pack", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    await createPack(db, "creator", { title: "Unbound", stickerIds: [sticker.stickerId], state: "published" });

    const id = crypto.randomUUID();
    const r2Key = objectKey("creator", id, "image/webp");
    await getObjectStore().put(r2Key, { bytes: Buffer.from("orphan"), contentType: "image/webp" });
    await db.insert(assets).values({
      id,
      ownerId: "creator",
      stickerId: sticker.stickerId,
      kind: "messenger_whatsapp",
      state: "ready",
      r2Key,
      mimeType: "image/webp",
      byteSize: 128,
      createdAt: new Date(),
      readyAt: new Date(),
    });

    await expect(createAssetDownload(db, "stranger", id)).rejects.toMatchObject({ status: 404 });
    await expect(createAssetDownload(db, "creator", id)).resolves.toBeDefined();
  });

  it("never echoes the creator's own filename to a borrower", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    await createPack(db, "creator", { title: "Names", stickerIds: [sticker.stickerId], state: "published" });
    const row = await db.select().from(assets).where(eq(assets.id, sticker.systemAssetId)).then(firstRow);
    expect(row?.originalFilename).toBe("system-secret-name.png");

    const own = await createAssetDownload(db, "creator", sticker.systemAssetId);
    expect(decodeURIComponent(own.url)).toContain("system-secret-name.png");

    const borrowed = await createAssetDownload(db, "stranger", sticker.systemAssetId);
    expect(decodeURIComponent(borrowed.url)).not.toContain("system-secret-name");
    expect(decodeURIComponent(borrowed.url)).toContain(`sticker-system-${sticker.systemAssetId}.png`);
  });

  it("leaves the strict owner-only resolver alone for writers", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    await createPack(db, "creator", { title: "Strict", stickerIds: [sticker.stickerId], state: "published" });
    // Readable through the marketplace, but still not *owned* — uploads and purges must keep
    // using the strict resolver, so this has to stay a 404.
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).resolves.toBeDefined();
    await expect(getOwnedAsset(db, "stranger", sticker.systemAssetId)).rejects.toMatchObject({ code: "ASSET_NOT_FOUND" });
  });

  it("closes access when the pack itself is tombstoned", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Doomed", stickerIds: [sticker.stickerId], state: "published" });
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).resolves.toBeDefined();
    await db.update(stickerPacks).set({ state: "removed" }).where(eq(stickerPacks.id, pack.id));
    await expect(createAssetDownload(db, "stranger", sticker.systemAssetId)).rejects.toMatchObject({ status: 404 });
  });
});
