import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import type { SubjectBounds } from "@/lib/images/subject-bounds";
import { LAYER_FIT, layerBounds, layoutDiagnostics } from "@/lib/layout/composition";
import {
  applyMeasuredPlacements,
  measuredPlacements,
  placementFromSubject,
  suggestFreePlacement,
} from "@/lib/layout/placement";

const fixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")),
);

function subject(crop: { left: number; top: number; width: number; height: number }, overrides: Partial<SubjectBounds> = {}): SubjectBounds {
  return {
    bbox: crop,
    crop,
    coverage: Math.max(crop.width, crop.height),
    source: { width: 1024, height: 1024 },
    ...overrides,
  };
}

/** The fixture with its hero moved, through the operation that keeps keyframes honest. */
function withHero(document: StickerDocument, anchor: { position: { x: number; y: number }; scale: { x: number; y: number } }): StickerDocument {
  const hero = document.layers.find((layer) => layer.id === "hero")!;
  return applyStickerOperationsV1(document, [{
    op: "setLayerAnimations",
    layerId: "hero",
    animations: hero.animations,
    anchor: { ...hero.anchor, ...anchor },
  }]);
}

describe("placementFromSubject", () => {
  it("maps the kept square onto the canvas: its centre is the position, its side over the fit box the scale", () => {
    const placement = placementFromSubject(subject({ left: 0.2, top: 0.3, width: 0.4, height: 0.4 }));
    expect(placement).toBeDefined();
    expect(placement!.position.x).toBeCloseTo(0.4, 10);
    expect(placement!.position.y).toBeCloseTo(0.5, 10);
    expect(placement!.scale.x).toBeCloseTo(0.4 / LAYER_FIT, 10);
    expect(placement!.scale.y).toBe(placement!.scale.x);
  });

  it("never asks for more than the fit box", () => {
    const placement = placementFromSubject(subject({ left: 0.05, top: 0.05, width: 0.89, height: 0.89 }));
    expect(placement!.scale).toEqual({ x: 1, y: 1 });
  });

  it("falls back to the plan when the measurement is not a separated part", () => {
    expect(placementFromSubject(undefined)).toBeUndefined();
    // The model returned the whole design rather than one element of it.
    expect(placementFromSubject(subject({ left: 0, top: 0, width: 1, height: 1 }))).toBeUndefined();
    // A stray pixel.
    expect(placementFromSubject(subject({ left: 0.5, top: 0.5, width: 0.01, height: 0.01 }))).toBeUndefined();
    // Not the square frame the canvas is.
    expect(placementFromSubject(subject(
      { left: 0.2, top: 0.3, width: 0.4, height: 0.4 },
      { source: { width: 1024, height: 768 } },
    ))).toBeUndefined();
  });
});

describe("measuredPlacements", () => {
  it("drops the parts that came back in the same place, keeping the rest", () => {
    const placements = measuredPlacements([
      { layerId: "a", subject: subject({ left: 0.1, top: 0.3, width: 0.3, height: 0.3 }) },
      { layerId: "b", subject: subject({ left: 0.1, top: 0.3, width: 0.3, height: 0.3 }) },
      { layerId: "c", subject: subject({ left: 0.6, top: 0.3, width: 0.3, height: 0.3 }) },
      { layerId: "d", subject: undefined },
    ]);
    expect([...placements.keys()]).toEqual(["c"]);
  });
});

describe("applyMeasuredPlacements", () => {
  it("moves the measured layers and recompiles their keyframes, leaving the others alone", () => {
    const source = fixture();
    const spark = source.layers.find((layer) => layer.id === "spark")!;
    const result = applyMeasuredPlacements(source, new Map([
      ["hero", { position: { x: 0.3, y: 0.4 }, scale: { x: 0.5, y: 0.5 } }],
    ]));
    const hero = result.layers.find((layer) => layer.id === "hero")!;
    expect(hero.anchor).toMatchObject({ position: { x: 0.3, y: 0.4 }, scale: { x: 0.5, y: 0.5 } });
    expect(hero.animation.position[0]).toMatchObject({ timeSeconds: 0, x: 0.3, y: 0.4 });
    expect(result.layers.find((layer) => layer.id === "spark")).toEqual(spark);
    expect(() => StickerDocumentSchema.parse(result)).not.toThrow();
  });

  it("is a no-op with nothing measured", () => {
    const source = fixture();
    expect(applyMeasuredPlacements(source, new Map())).toBe(source);
  });
});

describe("suggestFreePlacement", () => {
  it("centres a layer on an empty canvas", () => {
    const empty = { ...fixture(), layers: [] };
    expect(suggestFreePlacement(empty)).toEqual({ position: { x: 0.5, y: 0.5 }, scale: { x: 0.5, y: 0.5 } });
  });

  it("finds a spot that covers nothing next to a hero on one side", () => {
    const document = withHero(
      { ...fixture(), layers: fixture().layers.filter((layer) => layer.id === "hero") },
      { position: { x: 0.25, y: 0.5 }, scale: { x: 0.55, y: 0.55 } },
    );
    const placement = suggestFreePlacement(document);
    expect(placement.scale.x).toBe(0.5);
    expect(placement.position.x).toBeGreaterThan(0.5);
    const hero = layerBounds(document.layers[0]);
    const half = (LAYER_FIT * placement.scale.x) / 2;
    expect(placement.position.x - half).toBeGreaterThanOrEqual(hero.right);
    expect(placement.position.x - half).toBeGreaterThanOrEqual(0);
    expect(placement.position.x + half).toBeLessThanOrEqual(1);
  });

  it("settles for a corner, never the middle and never off canvas, when a hero fills the frame", () => {
    const document = { ...fixture(), layers: fixture().layers.filter((layer) => layer.id === "hero") };
    const placement = suggestFreePlacement(document);
    expect(placement.scale.x).toBe(0.5);
    expect(placement.position).not.toEqual({ x: 0.5, y: 0.5 });
    const half = (LAYER_FIT * placement.scale.x) / 2;
    expect(placement.position.x - half).toBeGreaterThanOrEqual(-1e-9);
    expect(placement.position.y - half).toBeGreaterThanOrEqual(-1e-9);
    expect(placement.position.x + half).toBeLessThanOrEqual(1 + 1e-9);
    expect(placement.position.y + half).toBeLessThanOrEqual(1 + 1e-9);
  });

  it("is deterministic", () => {
    expect(suggestFreePlacement(fixture())).toEqual(suggestFreePlacement(fixture()));
  });

  it("lands a layer that the diagnostics then report as on canvas", () => {
    const document = fixture();
    const placement = suggestFreePlacement(document);
    const spark = document.layers.find((layer) => layer.id === "spark")!;
    const placed = applyStickerOperationsV1(document, [{
      op: "setLayerAnimations",
      layerId: "spark",
      animations: spark.animations,
      anchor: { ...spark.anchor, ...placement },
    }]);
    expect(layoutDiagnostics(placed).offCanvasLayerIds).toEqual([]);
  });
});
