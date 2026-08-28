import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import {
  applyLayoutAdjustment,
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

  it("requires a complete layer-order permutation", () => {
    expect(() => applyLayoutAdjustment(fixture(), { order: ["hero"] }))
      .toThrow(/order must contain every layer exactly once/);
  });
});
