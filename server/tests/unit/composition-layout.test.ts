import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import {
  applyLayoutAdjustment,
  clampLayoutOnCanvas,
  LAYER_FIT,
  layerBounds,
  layoutDiagnostics,
} from "@/lib/layout/composition";

const fixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")),
);

describe("composition layout refinement", () => {
  it("reports likely obstruction but leaves the visual reviewer to decide whether it is intentional", () => {
    const diagnostics = layoutDiagnostics(fixture());
    expect(diagnostics.offCanvasLayerIds).toEqual([]);
    expect(diagnostics.substantialOverlaps).toContainEqual({
      layerIds: ["hero", "spark"],
      smallerLayerCoverage: 1,
    });
  });

  it("moves and reorders layers without changing artwork or declarative motion", () => {
    const source = fixture();
    const hero = source.layers.find((layer) => layer.id === "hero")!;
    const spark = source.layers.find((layer) => layer.id === "spark")!;
    const result = applyLayoutAdjustment(source, {
      placements: [{
        layerId: "spark",
        x: 0.72,
        y: 0.5,
        scaleX: 0.3,
        scaleY: 0.3,
        rotationDegrees: 12,
      }],
      order: ["spark", "hero"],
    });

    expect(result.layers.map((layer) => layer.id)).toEqual(["spark", "hero"]);
    const moved = result.layers.find((layer) => layer.id === "spark")!;
    const untouched = result.layers.find((layer) => layer.id === "hero")!;
    expect(moved.anchor).toMatchObject({
      position: { x: 0.72, y: 0.5 },
      scale: { x: 0.3, y: 0.3 },
      rotationDegrees: 12,
    });
    expect(moved.animations).toEqual(spark.animations);
    expect(untouched.animation).toEqual(hero.animation);
    expect(untouched.type === "image" && untouched.assetId).toBe(
      hero.type === "image" ? hero.assetId : false,
    );
  });

  it("rejects adjusted layouts whose rotated layer box leaves the canvas", () => {
    expect(() => applyLayoutAdjustment(fixture(), {
      placements: [{
        layerId: "hero",
        x: 0.1,
        y: 0.5,
        scaleX: 1,
        scaleY: 1,
        rotationDegrees: 20,
      }],
    })).toThrow(/Keep every complete layer box on canvas.*hero/);
  });

  // Production: an edit retained a sprite that already overhung the canvas and locked it, so every
  // adjustment of the additions was rejected on the locked layer and the review never finished.
  it("does not blame an adjustment for a layer that was already off canvas and left alone", () => {
    const hero = fixture().layers.find((layer) => layer.id === "hero")!;
    const source = applyStickerOperationsV1(fixture(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: hero.animations,
      anchor: { ...hero.anchor, position: { x: 0.1, y: 0.5 } },
    }]);
    expect(layoutDiagnostics(source).offCanvasLayerIds).toEqual(["hero"]);
    const spark = { layerId: "spark", x: 0.7, y: 0.5, scaleX: 0.2, scaleY: 0.2, rotationDegrees: 0 };

    expect(() => applyLayoutAdjustment(source, { placements: [spark] })).not.toThrow();
    expect(() => applyLayoutAdjustment(source, {
      placements: [spark, { layerId: "hero", x: 0.05, y: 0.5, scaleX: 1, scaleY: 1, rotationDegrees: 0 }],
    })).toThrow(/Keep every complete layer box on canvas.*hero/);
  });

  // A reviewer looking at a caption the build already stretched reaches for a wider box, and
  // honouring that literally would stretch it further. The narrower dimension is the one the
  // artwork can actually fit inside, and shrinking a layer can never invalidate the off-canvas and
  // overlap checks the rest of the layout was approved against.
  it("fits pixel artwork inside a non-square box instead of stretching it", () => {
    const result = applyLayoutAdjustment(fixture(), {
      placements: [{ layerId: "hero", x: 0.5, y: 0.5, scaleX: 0.9, scaleY: 0.35, rotationDegrees: 0 }],
    });
    expect(result.layers.find((layer) => layer.id === "hero")!.anchor.scale)
      .toEqual({ x: 0.35, y: 0.35 });
  });

  it("leaves an app-drawn layer free to occupy a non-square box", () => {
    const result = applyLayoutAdjustment(fixture(), {
      placements: [{ layerId: "spark", x: 0.5, y: 0.5, scaleX: 0.9, scaleY: 0.35, rotationDegrees: 0 }],
    });
    expect(result.layers.find((layer) => layer.id === "spark")!.anchor.scale)
      .toEqual({ x: 0.9, y: 0.35 });
  });

  it("requires a complete layer-order permutation", () => {
    expect(() => applyLayoutAdjustment(fixture(), { order: ["hero"] }))
      .toThrow(/order must contain every layer exactly once/);
  });

  // The native renderer fits glyphs inside their box rather than stretching them, so the box the
  // layout reasons about has to be the square the letters actually occupy.
  it("measures a text layer by the square its glyphs are fitted into", () => {
    const document = applyStickerOperationsV1(fixture(), [{
      op: "addLayer",
      layer: {
        id: "caption", name: "Caption", hidden: false, type: "text", text: "HI",
        font: "rounded", weight: "bold", paint: { type: "solid", color: "#FF0055" },
        anchor: {
          position: { x: 0.5, y: 0.5 }, scale: { x: 0.9, y: 0.35 }, rotationDegrees: 0, opacity: 1,
          trim: { start: 0, end: 1 },
        },
      },
    }] as Parameters<typeof applyStickerOperationsV1>[1]);
    const box = layerBounds(document.layers.find((layer) => layer.id === "caption")!);
    expect(box.right - box.left).toBeCloseTo(LAYER_FIT * 0.35, 10);
    expect(box.bottom - box.top).toBeCloseTo(LAYER_FIT * 0.35, 10);
  });
});

describe("clampLayoutOnCanvas", () => {
  const moveHero = (document: StickerDocument, anchor: { position?: { x: number; y: number }; scale?: { x: number; y: number } }) => {
    const hero = document.layers.find((layer) => layer.id === "hero")!;
    return applyStickerOperationsV1(document, [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: hero.animations,
      anchor: { ...hero.anchor, ...anchor },
    }]);
  };

  it("shifts a layer hanging off the edge back onto the canvas and touches nothing else", () => {
    const source = moveHero(fixture(), { position: { x: 0.1, y: 0.5 } });
    expect(layoutDiagnostics(source).offCanvasLayerIds).toEqual(["hero"]);
    const clamped = clampLayoutOnCanvas(source);
    const hero = clamped.layers.find((layer) => layer.id === "hero")!;
    expect(hero.anchor.position.x).toBeCloseTo(LAYER_FIT / 2, 10);
    expect(hero.anchor.position.y).toBe(0.5);
    expect(hero.anchor.scale).toEqual({ x: 1, y: 1 });
    // The compiler rounds emitted keyframes, so the anchor is matched to their precision.
    expect(hero.animation.position[0].timeSeconds).toBe(0);
    expect(hero.animation.position[0].x).toBeCloseTo(hero.anchor.position.x, 4);
    expect(hero.animation.position[0].y).toBe(0.5);
    expect(clamped.layers.find((layer) => layer.id === "spark"))
      .toEqual(source.layers.find((layer) => layer.id === "spark"));
    expect(layoutDiagnostics(clamped).offCanvasLayerIds).toEqual([]);
  });

  it("shrinks a layer bigger than the canvas before shifting it", () => {
    const source = moveHero(fixture(), { position: { x: 0.2, y: 0.5 }, scale: { x: 1.5, y: 1.5 } });
    const clamped = clampLayoutOnCanvas(source);
    const hero = clamped.layers.find((layer) => layer.id === "hero")!;
    expect(hero.anchor.scale.x).toBeCloseTo(1 / LAYER_FIT, 10);
    expect(hero.anchor.scale.y).toBe(hero.anchor.scale.x);
    expect(hero.anchor.position.x).toBeCloseTo(0.5, 10);
    expect(hero.anchor.position.y).toBe(0.5);
    expect(layoutDiagnostics(clamped).offCanvasLayerIds).toEqual([]);
  });

  it("returns the same document when every layer is already on canvas", () => {
    const source = fixture();
    expect(clampLayoutOnCanvas(source)).toBe(source);
  });
});
