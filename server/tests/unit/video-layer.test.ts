import { describe, expect, it } from "vitest";
import v3Fixture from "@/fixtures/sticker-document-v3.json";
import v4Fixture from "@/fixtures/sticker-document-v4.json";
import {
  applyStickerOperationsV1,
  CURRENT_DOCUMENT_VERSION,
  layerImageAssetIds,
  layerScaleIsAspectLocked,
  layerVideoAssetIds,
  StickerDocumentSchema,
  upcastV3ToV4,
} from "@/lib/contracts/sticker";

/** The v4 fixture with its hero video layer replaced by a patched copy. */
function withHero(overrides: Record<string, unknown>, document: Record<string, unknown> = {}): unknown {
  const source = { ...structuredClone(v4Fixture) as Record<string, unknown>, ...document };
  const layers = source.layers as Array<Record<string, unknown>>;
  layers[0] = { ...layers[0], ...overrides };
  return source;
}

describe("the v4 fixture", () => {
  it("parses, and its hero layer is a video", () => {
    const document = StickerDocumentSchema.parse(v4Fixture);
    expect(document.version).toBe(CURRENT_DOCUMENT_VERSION);
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the fixture's hero layer is not a video");
    expect(hero).toMatchObject({ keyColor: "green", frameCount: 48, frameRate: 24, playback: "loop" });
  });

  it("round-trips: parsing its own output changes nothing", () => {
    const once = StickerDocumentSchema.parse(v4Fixture);
    expect(StickerDocumentSchema.parse(once)).toEqual(once);
  });
});

describe("v3 documents upcast to v5 on read", () => {
  it("accepts the stored v3 fixture and restamps it, keeping its sequence layer", () => {
    const document = StickerDocumentSchema.parse(v3Fixture);
    expect(document.version).toBe(5);
    expect(document.layers[0].type).toBe("sequence");
  });

  it("is a pure restamp", () => {
    const upcast = upcastV3ToV4(v3Fixture as never) as { version: number };
    expect(upcast.version).toBe(4);
    expect({ ...upcast, version: 3 }).toEqual(v3Fixture);
  });
});

describe("VideoLayer contract", () => {
  it("requires a poster, unlike a sequence layer", () => {
    const raw = withHero({}) as { layers: Array<Record<string, unknown>> };
    delete raw.layers[0].posterAssetId;
    expect(() => StickerDocumentSchema.parse(raw)).toThrow();
  });

  it("only knows the two backdrops the server can shoot against", () => {
    expect(() => StickerDocumentSchema.parse(withHero({ keyColor: "magenta" }))).toThrow();
  });

  it("refuses a multi-frame clip in a static document", () => {
    const raw = withHero(
      { animations: [], animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [] } },
      { kind: "static", durationSeconds: 0, fps: 0, loop: "once", speed: 1 },
    ) as { layers: Array<Record<string, unknown>> };
    // The spark layer carries a pop-in, which a static document cannot hold either; drop it so the
    // one issue under test is the clip's.
    raw.layers = [raw.layers[0]];
    expect(() => StickerDocumentSchema.parse(raw)).toThrow(/static document/);
  });

  it("refuses a document that samples slower than its clip plays", () => {
    expect(() => StickerDocumentSchema.parse(withHero({}, { fps: 12 }))).toThrow(/frames would be dropped/);
  });

  it("retimes through setVideoPlayback and refuses it on other layers", () => {
    const document = StickerDocumentSchema.parse(v4Fixture);
    const retimed = applyStickerOperationsV1(document, [
      { op: "setVideoPlayback", layerId: "hero", playback: "pingPong", startSeconds: 0.5 },
    ]);
    const hero = retimed.layers[0];
    if (hero.type !== "video") throw new Error("the operation changed the layer kind");
    expect(hero.playback).toBe("pingPong");
    expect(hero.startSeconds).toBe(0.5);
    expect(() => applyStickerOperationsV1(document, [
      { op: "setVideoPlayback", layerId: "spark", playback: "once" },
    ])).toThrow(/not a video layer/);
  });

  it("reports the poster as its bitmap and the clip as its video", () => {
    const document = StickerDocumentSchema.parse(v4Fixture);
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the fixture's hero layer is not a video");
    // The server renders the poster; nothing server-side may ever be handed the MP4 as a picture.
    expect(layerImageAssetIds(hero)).toEqual([hero.posterAssetId]);
    expect(layerVideoAssetIds(hero)).toEqual([hero.assetId]);
    expect(layerVideoAssetIds(document.layers[1])).toEqual([]);
    expect(layerScaleIsAspectLocked("video")).toBe(true);
  });
});
