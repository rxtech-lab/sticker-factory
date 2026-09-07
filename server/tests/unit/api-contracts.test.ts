import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/api-responses-v1.json";
import {
  AssetDownloadResponseV1Schema,
  ChatMessagesResponseV1Schema,
  CreatePackRequestSchema,
  CreateUploadRequestSchema,
  MessengerRenditionsRequestSchema,
  LibrarySectionsResponseV1Schema,
  PackDetailV1Schema,
  PackListResponseV1Schema,
  PublishExportsRequestSchema,
  StickerListResponseV1Schema,
  UpdateStickerRequestSchema,
} from "@/lib/contracts/api";

describe("shared API fixtures", () => {
  it("validates the Messages library and download envelopes", () => {
    expect(StickerListResponseV1Schema.parse(fixture.stickerList).data[0].systemSticker?.byteSize).toBe(482_100);
    expect(AssetDownloadResponseV1Schema.parse(fixture.assetDownload).url).toContain("downloads.example.test");
    expect(ChatMessagesResponseV1Schema.parse(fixture.chatMessages).nextBeforeSequence).toBeNull();
    expect(PublishExportsRequestSchema.parse(fixture.publishExports).mp4Background?.type).toBe("linearGradient");
  });

  it("validates the marketplace and sectioned-library envelopes", () => {
    const packs = PackListResponseV1Schema.parse(fixture.packList);
    expect(packs.data[0]).toMatchObject({ installCount: 128, installed: false, isMine: false });
    expect(packs.data[0].creator.displayName).toBe("Mika Lin");
    expect(packs.data[0].monetization).toEqual({ kind: "free", priceCents: 0, currency: "USD" });

    const detail = PackDetailV1Schema.parse(fixture.packDetail);
    expect(detail.stickers[0].systemSticker?.assetId).toBe("44444444-4444-4444-8444-444444444444");

    const sections = LibrarySectionsResponseV1Schema.parse(fixture.librarySections);
    expect(sections.sections.map((section) => section.kind)).toEqual(["mine", "pack"]);
    // "My Stickers" is always first and never carries a creator byline.
    expect(sections.sections[0]).toMatchObject({ id: "mine", creator: null, packId: null });
    expect(sections.sections[1].creator?.handle).toBe("mika-lin-4f2a9c");
    // A pack sticker is exactly a StickerSummary, so both clients decode it with no new model —
    // and its system rendition is the same shape the download envelope describes.
    expect(sections.sections[0].stickers[0].systemSticker?.assetId)
      .toBe(AssetDownloadResponseV1Schema.parse(fixture.assetDownload).asset.id);
  });

  it("bounds pack authoring requests", () => {
    expect(CreatePackRequestSchema.parse({ title: "  Cozy Cats  " })).toEqual({
      title: "Cozy Cats",
      stickerIds: [],
      state: "draft",
    });
    expect(() => CreatePackRequestSchema.parse({
      title: "Too big",
      stickerIds: Array.from({ length: 61 }, () => "22222222-2222-4222-8222-222222222222"),
    })).toThrow();
    expect(() => CreatePackRequestSchema.parse({ title: "" })).toThrow();
    // `.strict()` keeps a client from smuggling in fields the server would silently ignore.
    expect(() => CreatePackRequestSchema.parse({ title: "Fine", installCount: 9000 })).toThrow();
  });

  it("validates sticker renames", () => {
    expect(UpdateStickerRequestSchema.parse({ title: "  Happy Cloud  " })).toEqual({ title: "Happy Cloud" });
    expect(() => UpdateStickerRequestSchema.parse({ title: "   " })).toThrow();
    expect(() => UpdateStickerRequestSchema.parse({ title: "x".repeat(101) })).toThrow();
    expect(() => UpdateStickerRequestSchema.parse({ title: "Cloud", status: "published" })).toThrow();
  });

  it("enforces the system rendition and export MIME matrix", () => {
    expect(() => CreateUploadRequestSchema.parse({
      kind: "system",
      mimeType: "image/jpeg",
      byteSize: 40_000,
      filename: "bad.jpg",
    })).toThrow(/PNG, APNG, or GIF/);
    expect(() => CreateUploadRequestSchema.parse({
      kind: "mp4",
      mimeType: "image/png",
      byteSize: 40_000,
      filename: "bad.png",
    })).toThrow(/video\/mp4/);
  });

  it("enforces each messenger's container and ceiling", () => {
    const upload = (fields: Record<string, unknown>) => CreateUploadRequestSchema.parse({
      byteSize: 40_000,
      filename: "sticker.bin",
      ...fields,
    });

    expect(upload({ kind: "messenger_whatsapp", mimeType: "image/webp" }).kind).toBe("messenger_whatsapp");
    // Telegram takes two containers, because a static sticker goes as a still and an animated one
    // as a video. Which is correct for a given sticker is settled at bind time, not here.
    expect(upload({ kind: "messenger_telegram", mimeType: "image/png" }).kind).toBe("messenger_telegram");
    expect(upload({ kind: "messenger_telegram", mimeType: "video/webm" }).kind).toBe("messenger_telegram");

    expect(() => upload({ kind: "messenger_whatsapp", mimeType: "image/png" })).toThrow(/image\/webp/);
    expect(() => upload({ kind: "messenger_telegram", mimeType: "image/webp" })).toThrow(/image\/png or video\/webm/);

    // WebM exists in this API for exactly one purpose; nothing else may claim it.
    expect(() => upload({ kind: "master", mimeType: "video/webm" })).toThrow(/Only Telegram renditions/);
    expect(() => upload({ kind: "webp", mimeType: "video/webm" })).toThrow(/Only Telegram renditions/);

    // The ceilings are the messengers' own, and they are KiB — a decimal 500_000 would let the
    // client's last ladder rung through by 2.4 KB and be refused after the hand-off.
    expect(() => upload({ kind: "messenger_whatsapp", mimeType: "image/webp", byteSize: 500 * 1024 + 1 }))
      .toThrow(/500 KB/);
    expect(upload({ kind: "messenger_whatsapp", mimeType: "image/webp", byteSize: 500 * 1024 }).byteSize)
      .toBe(500 * 1024);
    expect(() => upload({ kind: "messenger_telegram", mimeType: "video/webm", byteSize: 256 * 1024 + 1 }))
      .toThrow(/256 KB/);
    expect(() => upload({ kind: "messenger_telegram", mimeType: "image/png", byteSize: 512 * 1024 + 1 }))
      .toThrow(/512 KB/);
  });

  it("validates the messenger rendition bind request", () => {
    const revisionId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    const assetId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    const other = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

    expect(MessengerRenditionsRequestSchema.parse({ revisionId, whatsappAssetId: assetId }).whatsappAssetId)
      .toBe(assetId);
    // Each destination binds on its own: fitting WhatsApp says nothing about fitting Telegram.
    expect(MessengerRenditionsRequestSchema.parse({ revisionId, telegramAssetId: assetId }).telegramAssetId)
      .toBe(assetId);
    expect(MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "🐱" }).emoji).toBe("🐱");

    // Nothing to write at all is a client bug worth surfacing, not a no-op to absorb.
    expect(() => MessengerRenditionsRequestSchema.parse({ revisionId })).toThrow(/at least one/);
    // The two messengers take different containers, so one file can never be both.
    expect(() => MessengerRenditionsRequestSchema.parse({
      revisionId,
      whatsappAssetId: assetId,
      telegramAssetId: assetId,
    })).toThrow(/cannot share one asset/);
    expect(MessengerRenditionsRequestSchema.parse({
      revisionId,
      whatsappAssetId: assetId,
      telegramAssetId: other,
    }).telegramAssetId).toBe(other);

    // One grapheme that is an emoji — counted, not measured, so a flag or a family still passes.
    expect(MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "🇯🇵" }).emoji).toBe("🇯🇵");
    expect(MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "👩‍👩‍👧" }).emoji).toBe("👩‍👩‍👧");
    expect(MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "1️⃣" }).emoji).toBe("1️⃣");
    expect(() => MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "🐱🐶" })).toThrow(/one emoji/);
    expect(() => MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "cat" })).toThrow(/one emoji/);
    expect(() => MessengerRenditionsRequestSchema.parse({ revisionId, emoji: "" })).toThrow();
  });
});
