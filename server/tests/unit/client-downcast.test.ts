import { describe, expect, it } from "vitest";
import v3Fixture from "@/fixtures/sticker-document-v3.json";
import {
  clientDocumentVersion,
  CURRENT_DOCUMENT_VERSION,
  downcastForClient,
  MIN_CLIENT_DOCUMENT_VERSION,
  StickerDocumentSchema,
} from "@/lib/contracts/sticker";
import { downcastStickerDetail } from "@/lib/services/stickers";

const parsed = () => StickerDocumentSchema.parse(v3Fixture);
const headers = (value?: string) => ({
  headers: { get: (name: string) => (name === "x-sticker-contract" && value !== undefined ? value : null) },
});

/**
 * The property this whole file exists for: no client that predates a layer kind may ever be handed
 * one. iOS decodes `type` into a closed enum, so a single unknown layer fails the document, then
 * the sticker payload, and the user is left with a project that will not open — on a build already
 * in the field, where it cannot be fixed.
 */
describe("downcastForClient", () => {
  it("hands a current client the document unchanged", () => {
    const document = parsed();
    expect(downcastForClient(document, CURRENT_DOCUMENT_VERSION)).toBe(document);
  });

  it("replaces a sequence layer with its poster for an older client", () => {
    const document = parsed();
    const result = downcastForClient(document, 2) as typeof document;

    expect(result.version).toBe(2);
    expect(result.layers).toHaveLength(2);
    const hero = result.layers[0];
    expect(hero.type).toBe("image");
    if (hero.type !== "image") throw new Error("the downcast did not produce an image layer");

    const source = document.layers[0];
    if (source.type !== "sequence") throw new Error("the fixture's hero layer is not a sequence");
    expect(hero.assetId).toBe(source.posterAssetId);
    // The motion the AI authored has to survive, or the sticker degrades to a static image rather
    // than to a still subject that still moves.
    expect(hero.id).toBe(source.id);
    expect(hero.name).toBe(source.name);
    expect(hero.anchor).toEqual(source.anchor);
    expect(hero.animations).toEqual(source.animations);
    expect(hero.animation).toEqual(source.animation);
    expect(hero.blendMode).toBe(source.blendMode);
    expect(hero.contentMode).toBe(source.contentMode);
  });

  it("leaves every other layer alone", () => {
    const document = parsed();
    const result = downcastForClient(document, 2) as typeof document;
    expect(result.layers[1]).toEqual(document.layers[1]);
    expect(result.durationSeconds).toBe(document.durationSeconds);
    expect(result.loop).toBe(document.loop);
  });

  it("carries none of the sequence's own fields onto the image layer", () => {
    // An `image` layer is `.strict()`, so a leaked `frameCount` would make the downcast output
    // unparseable — by the old client, which is the one population that cannot be fixed later.
    const result = downcastForClient(parsed(), 2) as { layers: Array<Record<string, unknown>> };
    for (const key of ["columns", "rows", "frameCount", "frameRate", "playback", "startSeconds", "posterAssetId"]) {
      expect(result.layers[0]).not.toHaveProperty(key);
    }
  });

  it("drops a posterless capture rather than pointing an image layer at the whole atlas", () => {
    const raw = structuredClone(v3Fixture) as Record<string, unknown>;
    const layers = raw.layers as Array<Record<string, unknown>>;
    delete layers[0].posterAssetId;
    const result = downcastForClient(StickerDocumentSchema.parse(raw), 2) as { layers: Array<{ type: string }> };
    // An image layer aimed at the atlas would draw the entire sprite sheet at once, which reads as
    // a rendering fault. One missing layer is the honest degradation.
    expect(result.layers).toHaveLength(1);
    expect(result.layers[0].type).toBe("particle");
  });

  it("produces something the v2 half of the contract still accepts", () => {
    // The strongest form of the guarantee: the output is not merely stamped v2, it parses as v2.
    const result = downcastForClient(parsed(), 2);
    const reparsed = StickerDocumentSchema.parse(result);
    expect(reparsed.layers.every((layer) => layer.type !== "sequence")).toBe(true);
  });
});

describe("clientDocumentVersion", () => {
  it("assumes the oldest contract when the header is absent", () => {
    // A client that predates the header is exactly the population the downcast protects, so the
    // default has to be the floor. Guessing generously here is what would brick a project.
    expect(clientDocumentVersion(headers())).toBe(MIN_CLIENT_DOCUMENT_VERSION);
  });

  it("honours a header a client actually sends", () => {
    expect(clientDocumentVersion(headers("3"))).toBe(3);
  });

  it("clamps nonsense to the floor rather than trusting it", () => {
    for (const value of ["", "abc", "0", "-1", "3.5", "NaN"]) {
      expect(clientDocumentVersion(headers(value))).toBe(MIN_CLIENT_DOCUMENT_VERSION);
    }
  });

  it("clamps a client claiming a version we do not write yet", () => {
    expect(clientDocumentVersion(headers("99"))).toBe(CURRENT_DOCUMENT_VERSION);
  });
});

describe("downcastStickerDetail", () => {
  const detail = () => ({
    id: "sticker",
    revisions: [{ id: "rev", document: parsed() }],
  });

  it("degrades every revision in the payload, not just the active one", () => {
    const result = downcastStickerDetail(detail(), 2) as { revisions: Array<{ document: { layers: Array<{ type: string }> } }> };
    expect(result.revisions[0].document.layers.some((layer) => layer.type === "sequence")).toBe(false);
  });

  it("passes a current client the payload untouched", () => {
    const source = detail();
    expect(downcastStickerDetail(source, CURRENT_DOCUMENT_VERSION)).toBe(source);
  });
});
