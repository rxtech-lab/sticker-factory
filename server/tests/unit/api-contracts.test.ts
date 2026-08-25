import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/api-responses-v1.json";
import {
  AssetDownloadResponseV1Schema,
  ChatMessagesResponseV1Schema,
  CreateUploadRequestSchema,
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
