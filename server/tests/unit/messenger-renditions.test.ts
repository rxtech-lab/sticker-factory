import { and, eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers } from "@/lib/db/schema";
import { bindMessengerRenditions } from "@/lib/services/stickers";
import { getObjectStore, MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

/**
 * `bindMessengerRenditions` is the one place in the codebase that writes to a revision after it has
 * been published, so what it refuses matters as much as what it accepts.
 */
describe("bindMessengerRenditions", () => {
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

  /** A ready messenger rendition sitting on the sticker, not yet bound to its revision. */
  async function seedRendition(
    ownerId: string,
    stickerId: string | null,
    kind: "messenger_whatsapp" | "messenger_telegram",
    overrides: { mimeType?: string; frameCount?: number | null } = {},
  ) {
    const id = crypto.randomUUID();
    const mimeType = overrides.mimeType ?? (kind === "messenger_whatsapp" ? "image/webp" : "image/png");
    const r2Key = objectKey(ownerId, id, mimeType);
    await getObjectStore().put(r2Key, { bytes: Buffer.from(id), contentType: mimeType });
    await db.insert(assets).values({
      id,
      ownerId,
      stickerId,
      kind,
      state: "ready",
      r2Key,
      mimeType,
      byteSize: 64_000,
      width: 512,
      height: 512,
      frameCount: overrides.frameCount === undefined ? 1 : overrides.frameCount,
      sha256: id.replace(/-/g, "").padEnd(64, "0"),
      hasAlpha: true,
      originalFilename: `${kind}.bin`,
      createdAt: new Date(),
      readyAt: new Date(),
    });
    return id;
  }

  const revisionOf = (revisionId: string) =>
    db.select().from(stickerRevisions).where(eq(stickerRevisions.id, revisionId)).then(firstRow);

  it("binds both renditions and the emoji to the active revision", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { title: "Wave" });
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram");

    const summary = await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
      telegramAssetId: telegram,
      emoji: "🐱",
    });

    // The summary comes back whole, so the client can mark the sticker sendable without re-listing.
    expect(summary.whatsappAsset?.id).toBe(whatsapp);
    expect(summary.telegramAsset?.id).toBe(telegram);
    expect(summary.messengerEmoji).toBe("🐱");

    const revision = await revisionOf(sticker.revisionId);
    expect(revision?.whatsappAssetId).toBe(whatsapp);
    expect(revision?.telegramAssetId).toBe(telegram);
  });

  /**
   * The case the two independent columns exist for: artwork that clears WhatsApp's 500 KB animated
   * ceiling and misses Telegram's 256 KB one. Binding the half that worked is the whole point.
   */
  it("binds one messenger without the other", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");

    const summary = await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    });

    expect(summary.whatsappAsset?.id).toBe(whatsapp);
    expect(summary.telegramAsset).toBeNull();
  });

  /** A second call must not blank the column the first one filled. */
  it("leaves an already-bound rendition alone when the other arrives later", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram");

    await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    });
    const summary = await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      telegramAssetId: telegram,
    });

    expect(summary.whatsappAsset?.id).toBe(whatsapp);
    expect(summary.telegramAsset?.id).toBe(telegram);
  });

  it("accepts an emoji on its own without touching the renditions", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { messengerRenditions: true });
    const summary = await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      emoji: "🌊",
    });
    expect(summary.messengerEmoji).toBe("🌊");
    expect(summary.whatsappAsset?.id).toBe(sticker.whatsappAssetId);
    expect(summary.telegramAsset?.id).toBe(sticker.telegramAssetId);
  });

  it("refuses a rendition bound to the wrong column", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram");
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: telegram,
    })).rejects.toMatchObject({ status: 422, code: "INVALID_WHATSAPP_RENDITION" });
  });

  it("refuses artwork belonging to another sticker", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const other = await seedPublishedSticker(db, "creator", { title: "Other" });
    const whatsapp = await seedRendition("creator", other.stickerId, "messenger_whatsapp");
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 422, code: "ASSET_STICKER_MISMATCH" });
  });

  it("refuses another user's sticker without confirming it exists", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    await expect(bindMessengerRenditions(db, "stranger", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 404 });
  });

  /**
   * A still WhatsApp file under an animated sticker would be handed to a pack the messenger has
   * been told is animated, and refused on arrival — where nothing in this app can explain it.
   */
  it("refuses a still WhatsApp rendition on an animated sticker", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { kind: "animated" });
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp", { frameCount: 1 });
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 422, code: "WHATSAPP_RENDITION_MISMATCH" });
  });

  /** Telegram's two containers are told apart by mime type, because a WebM reports no frames. */
  it("refuses a PNG Telegram rendition on an animated sticker", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { kind: "animated" });
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram", { mimeType: "image/png" });
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      telegramAssetId: telegram,
    })).rejects.toMatchObject({ status: 422, code: "TELEGRAM_RENDITION_MISMATCH" });
  });

  it("accepts a WebM Telegram rendition on an animated sticker", async () => {
    const sticker = await seedPublishedSticker(db, "creator", { kind: "animated" });
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram", {
      mimeType: "video/webm",
      frameCount: null,
    });
    const summary = await bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      telegramAssetId: telegram,
    });
    expect(summary.telegramAsset?.id).toBe(telegram);
  });

  it("refuses a WebM Telegram rendition on a static sticker", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const telegram = await seedRendition("creator", sticker.stickerId, "messenger_telegram", {
      mimeType: "video/webm",
      frameCount: null,
    });
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      telegramAssetId: telegram,
    })).rejects.toMatchObject({ status: 422, code: "TELEGRAM_RENDITION_MISMATCH" });
  });

  /**
   * The guard that makes writing to a published revision safe: a device edit moves the active
   * revision, and a bind that was already in flight must lose rather than staple renditions onto
   * artwork that has moved on.
   */
  it("refuses a revision that is no longer active", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    // A real successor revision, the way a device edit makes one — a bare UUID is refused by the
    // `validate_sticker_active_revision` trigger, which is itself the first line of this defence.
    const edited = await revisionOf(sticker.revisionId);
    const successorId = crypto.randomUUID();
    await db.insert(stickerRevisions).values({
      ...edited!,
      id: successorId,
      parentRevisionId: sticker.revisionId,
      whatsappAssetId: null,
      telegramAssetId: null,
    });
    await db.update(stickers).set({ activeRevisionId: successorId })
      .where(eq(stickers.id, sticker.stickerId));
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 409, code: "REVISION_NOT_ACTIVE" });
  });

  it("refuses a sticker that is not published", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, sticker.stickerId));
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 409, code: "STICKER_NOT_PUBLISHED" });
  });

  it("refuses an asset that never finished uploading", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const whatsapp = await seedRendition("creator", sticker.stickerId, "messenger_whatsapp");
    await db.update(assets).set({ state: "pending" }).where(and(
      eq(assets.id, whatsapp),
      eq(assets.ownerId, "creator"),
    ));
    await expect(bindMessengerRenditions(db, "creator", sticker.stickerId, {
      revisionId: sticker.revisionId,
      whatsappAssetId: whatsapp,
    })).rejects.toMatchObject({ status: 422 });
  });
});
