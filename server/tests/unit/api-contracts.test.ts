import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/api-responses-v1.json";
import {
  AssetDownloadResponseV1Schema,
  ChatMessagesResponseV1Schema,
  CreatePackRequestSchema,
  CreateUploadRequestSchema,
  LibrarySectionsResponseV1Schema,
  PackDetailV1Schema,
  PackListResponseV1Schema,
  PublishExportsRequestSchema,
  StickerListResponseV1Schema,
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
});
