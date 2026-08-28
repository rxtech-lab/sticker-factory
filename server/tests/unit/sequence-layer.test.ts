import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import v1Fixture from "@/fixtures/sticker-document-v1.json";
import v3Fixture from "@/fixtures/sticker-document-v3.json";
import {
  applyStickerOperationsV1,
  CURRENT_DOCUMENT_VERSION,
  StickerDocumentSchema,
  upcastV2ToV3,
  type StickerDocument,
} from "@/lib/contracts/sticker";

const v2Fixture = JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8"));

/** The v3 fixture with its hero sequence layer replaced by a patched copy. */
function withHero(overrides: Record<string, unknown>): unknown {
  const document = structuredClone(v3Fixture) as Record<string, unknown>;
  const layers = document.layers as Array<Record<string, unknown>>;
  layers[0] = { ...layers[0], ...overrides };
  return document;
}

describe("the v3 fixture", () => {
  it("parses, and its hero layer is a sequence", () => {
    const document = StickerDocumentSchema.parse(v3Fixture);
    expect(document.version).toBe(CURRENT_DOCUMENT_VERSION);
    const hero = document.layers[0];
    if (hero.type !== "sequence") throw new Error("the fixture's hero layer is not a sequence");
    expect(hero).toMatchObject({ columns: 4, rows: 3, frameCount: 12, frameRate: 10, playback: "loop" });
  });

  it("round-trips: parsing its own output changes nothing", () => {
    const once = StickerDocumentSchema.parse(v3Fixture);
    expect(StickerDocumentSchema.parse(once)).toEqual(once);
  });
});

describe("SequenceLayer bounds", () => {
  it("rejects a frame count the grid cannot hold", () => {
    expect(() => StickerDocumentSchema.parse(withHero({ frameCount: 13 })))
      .toThrow(/grid holds only 12/);
  });

  it("accepts a grid with unused trailing cells", () => {
    // 10 of 12 cells used is ordinary: a dropped frame renumbers the sequence rather than leaving
    // a hole, so the last row is often short.
    expect(() => StickerDocumentSchema.parse(withHero({ frameCount: 10 }))).not.toThrow();
  });

  it("rejects a grid larger than the contract allows", () => {
    expect(() => StickerDocumentSchema.parse(withHero({ columns: 9 }))).toThrow();
    expect(() => StickerDocumentSchema.parse(withHero({ rows: 0 }))).toThrow();
  });

  it("rejects unknown fields", () => {
    expect(() => StickerDocumentSchema.parse(withHero({ spriteSheet: true }))).toThrow();
  });

  it("defaults playback and startSeconds", () => {
    const document = structuredClone(v3Fixture) as Record<string, unknown>;
    const layers = document.layers as Array<Record<string, unknown>>;
    const { playback, startSeconds, ...bare } = layers[0];
    void playback;
    void startSeconds;
    layers[0] = bare;
    const parsed = StickerDocumentSchema.parse(document);
    const hero = parsed.layers[0];
    if (hero.type !== "sequence") throw new Error("the fixture's hero layer is not a sequence");
    expect(hero.playback).toBe("loop");
    expect(hero.startSeconds).toBe(0);
  });
});

describe("document-level sequence rules", () => {
  it("refuses multi-frame footage in a static document", () => {
    const document = structuredClone(v3Fixture) as Record<string, unknown>;
    document.kind = "static";
    document.durationSeconds = 0;
    document.fps = 0;
    document.loop = "once";
    // The particle layer's compiled keyframes are timed against the animated duration, so drop it
    // rather than have a second, unrelated failure mask the one under test.
    document.layers = [(document.layers as unknown[])[0]];
    expect(() => StickerDocumentSchema.parse(document)).toThrow(/static document/);
  });

  it("allows a single-frame sequence in a static document", () => {
    const document = structuredClone(v3Fixture) as Record<string, unknown>;
    document.kind = "static";
    document.durationSeconds = 0;
    document.fps = 0;
    document.loop = "once";
    const hero = { ...(document.layers as Array<Record<string, unknown>>)[0], frameCount: 1 };
    document.layers = [hero];
    expect(() => StickerDocumentSchema.parse(document)).not.toThrow();
  });

  it("refuses a document whose fps would drop captured frames", () => {
    const document = structuredClone(v3Fixture) as Record<string, unknown>;
    document.fps = 8;
    expect(() => StickerDocumentSchema.parse(document)).toThrow(/frames would be dropped/);
  });
});

describe("setSequencePlayback", () => {
  const base = StickerDocumentSchema.parse(v3Fixture) as StickerDocument;

  it("retimes the footage without touching anything else", () => {
    const result = applyStickerOperationsV1(base, [
      { op: "setSequencePlayback", layerId: "hero", playback: "pingPong", startSeconds: 0.25 },
    ]);
    const hero = result.layers[0];
    if (hero.type !== "sequence") throw new Error("the operation changed the layer kind");
    expect(hero.playback).toBe("pingPong");
    expect(hero.startSeconds).toBe(0.25);
    expect(hero.assetId).toBe((base.layers[0] as typeof hero).assetId);
    expect(result.layers[1]).toEqual(base.layers[1]);
  });

  it("refuses a layer that is not a sequence", () => {
    expect(() => applyStickerOperationsV1(base, [
      { op: "setSequencePlayback", layerId: "spark", playback: "once" },
    ])).toThrow(/not a sequence layer/);
  });

  it("leaves the source document untouched", () => {
    applyStickerOperationsV1(base, [{ op: "setSequencePlayback", layerId: "hero", playback: "once" }]);
    const hero = base.layers[0];
    if (hero.type !== "sequence") throw new Error("the source document was mutated");
    expect(hero.playback).toBe("loop");
  });
});

describe("version chain", () => {
  it("upcasts the stored v2 fixture to the current version", () => {
    const document = StickerDocumentSchema.parse(v2Fixture);
    expect(document.version).toBe(CURRENT_DOCUMENT_VERSION);
    // v2 -> v3 only restamps, so everything else must survive byte for byte.
    expect(document.layers.map((layer) => layer.type)).toEqual(["image", "particle"]);
    expect(document.durationSeconds).toBe(v2Fixture.durationSeconds);
  });

  it("still upcasts v1 all the way through v2", () => {
    const document = StickerDocumentSchema.parse(v1Fixture);
    expect(document.version).toBe(CURRENT_DOCUMENT_VERSION);
    expect(document.speed).toBe(1);
  });

  it("upcastV2ToV3 only moves the stamp", () => {
    const v2 = StickerDocumentSchema.parse(v2Fixture);
    const restamped = upcastV2ToV3({ ...v2, version: 2 } as never) as Record<string, unknown>;
    expect(restamped.version).toBe(3);
    expect({ ...restamped, version: undefined }).toEqual({ ...v2, version: undefined });
  });

  it("refuses a v2 document that smuggles in a sequence layer", () => {
    // A v2 stamp is a promise to older clients that every layer is one they can decode. Accepting
    // this would let a sequence layer reach a build that throws on it.
    const document = structuredClone(v3Fixture) as Record<string, unknown>;
    document.version = 2;
    expect(() => StickerDocumentSchema.parse(document)).toThrow();
  });
});
