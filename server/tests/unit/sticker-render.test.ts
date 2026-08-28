import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { sampleLayerState, loopedTime } from "@/lib/animation/sample";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { documentSvg, referencedAssetIds, renderSticker } from "@/lib/render/sticker-render";
import { shapeGeometry } from "@/lib/render/shapes";

const fixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")),
);

/** PNG magic number. A `sharp` failure would hand back something else, or throw. */
const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47];

function withShape(base: StickerDocument, id: string, shape: unknown, animations: unknown[] = []): StickerDocument {
  return applyStickerOperationsV1(base, [
    {
      op: "addLayer",
      layer: {
        id,
        name: id,
        hidden: false,
        anchor: {
          position: { x: 0.5, y: 0.5 },
          scale: { x: 0.4, y: 0.4 },
          rotationDegrees: 0,
          opacity: 1,
          trim: { start: 0, end: 1 },
        },
        blendMode: "normal",
        type: "shape",
        shape,
        fill: { type: "solid", color: "#FFD166" },
        cornerRadius: 0.12,
        animations: [],
        animation: {
          position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
        },
      },
    } as never,
    ...(animations.length > 0
      ? [{ op: "setLayerAnimations", layerId: id, animations } as never]
      : []),
  ]);
}

describe("shape geometry", () => {
  it("emits a closed path for every parameterised kind", () => {
    const kinds = [
      { kind: "triangle" }, { kind: "heart" }, { kind: "burst" },
      { kind: "star", points: 5, innerRatio: 0.42 }, { kind: "polygon", sides: 6 },
    ] as const;
    for (const kind of kinds) {
      const geometry = shapeGeometry(kind, 0.12);
      expect(geometry.kind, kind.kind).toBe("path");
      if (geometry.kind !== "path") continue;
      expect(geometry.d.startsWith("M"), kind.kind).toBe(true);
      expect(geometry.d.endsWith("Z"), kind.kind).toBe(true);
      // Everything must land inside the unit box, or a shape would spill past its own layer.
      for (const value of geometry.d.match(/-?\d+\.?\d*/g) ?? []) {
        expect(Number(value)).toBeGreaterThanOrEqual(-0.001);
        expect(Number(value)).toBeLessThanOrEqual(1.001);
      }
    }
  });

  it("keeps circles and rounded rectangles as primitives", () => {
    // Rounding a rect through path data would approximate what SVG can do exactly.
    expect(shapeGeometry({ kind: "circle" }, 0.12).kind).toBe("ellipse");
    expect(shapeGeometry({ kind: "roundedRectangle" }, 0.2)).toEqual({ kind: "rect", cornerRadius: 0.2 });
    expect(shapeGeometry({ kind: "capsule" }, 0.12)).toEqual({ kind: "rect", cornerRadius: 0.5 });
  });

  it("passes author path data through untouched", () => {
    const geometry = shapeGeometry({ kind: "path", d: "M0,0 L1,1" }, 0.12);
    expect(geometry).toEqual({ kind: "path", d: "M0,0 L1,1" });
  });
});

describe("sampling", () => {
  it("resolves an empty channel to the layer's anchor rather than to zero", () => {
    const base = fixture();
    const layer = base.layers[0];
    const state = sampleLayerState(layer, 0);
    expect(state.position).toEqual(layer.anchor.position);
    expect(state.opacity).toBe(layer.anchor.opacity);
  });

  it("reads a wipe as closed at its start and open at its end", () => {
    const document = withShape(fixture(), "wiped", { kind: "circle" }, [
      { type: "wipeIn", direction: "right", duration: 1, easing: "linear" },
    ]);
    const layer = document.layers.find((item) => item.id === "wiped")!;
    expect(sampleLayerState(layer, 0).wipe.end).toBe(0);
    expect(sampleLayerState(layer, 1).wipe.end).toBe(1);
    // Half way through a linear wipe the window is half open — this is the value the mask renders.
    expect(sampleLayerState(layer, 0.5).wipe.end).toBeCloseTo(0.5, 5);
  });

  it("wraps a looping timeline and folds a ping-pong one back", () => {
    expect(loopedTime(2.5, { durationSeconds: 2, loop: "loop" })).toBeCloseTo(0.5, 5);
    expect(loopedTime(2.5, { durationSeconds: 2, loop: "pingPong" })).toBeCloseTo(1.5, 5);
    expect(loopedTime(9, { durationSeconds: 2, loop: "once" })).toBe(2);
  });
});

describe("referenced assets", () => {
  it("collects artwork, masks, svg sources and the background", () => {
    const base = fixture();
    const ids = referencedAssetIds(base);
    const imageLayer = base.layers.find((layer) => layer.type === "image");
    expect(imageLayer).toBeDefined();
    if (imageLayer?.type === "image") expect(ids).toContain(imageLayer.assetId);
  });

  it("returns nothing for a document that draws itself", () => {
    const document = withShape(
      { ...fixture(), layers: [] } as StickerDocument,
      "solo",
      { kind: "star", points: 5, innerRatio: 0.4 },
    );
    expect(referencedAssetIds(document)).toEqual([]);
  });
});

describe("rendering", () => {
  it("draws a contact sheet for an animated document", async () => {
    const render = await renderSticker(fixture(), new Map());
    expect(render.times.length).toBeGreaterThan(1);
    expect([...render.png.slice(0, 4)]).toEqual(PNG_SIGNATURE);
    // Every sampled instant must sit inside the authored timeline, or a tile would be blank.
    for (const time of render.times) {
      expect(time).toBeGreaterThanOrEqual(0);
      expect(time).toBeLessThanOrEqual(fixture().durationSeconds);
    }
  });

  it("draws a single frame for a static document", async () => {
    const animated = fixture();
    // A static document is its own variant, not the animated one with the motion removed: duration,
    // fps, loop and speed are all pinned literals, and it may carry no keyframes at all.
    const staticDocument = StickerDocumentSchema.parse({
      version: animated.version,
      canvas: animated.canvas,
      background: animated.background,
      mp4Background: animated.mp4Background,
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      speed: 1,
      layers: animated.layers.map((layer) => ({
        ...layer,
        animations: [],
        animation: {
          position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
        },
      })),
    });
    const render = await renderSticker(staticDocument, new Map());
    expect(render.times).toEqual([0]);
    expect(render.width).toBe(render.height - 22);
  });

  it("stays small enough to hand back through the model's context", async () => {
    // The render is fed into the message history, where `estimateTokens` stringifies it. A sheet
    // that grew into the hundreds of kilobytes would trip compaction and start pruning tool calls.
    const render = await renderSticker(fixture(), new Map());
    expect(render.png.byteLength).toBeLessThan(200_000);
  });

  it("draws a placeholder for artwork it could not load instead of dropping the layer", () => {
    const { svg } = documentSvg(fixture(), new Map());
    expect(svg).toContain("artwork");
  });

  it("produces well-formed markup with balanced defs", () => {
    const document = withShape(fixture(), "wiped", { kind: "heart" }, [
      { type: "wipeIn", direction: "up", softness: 0.2, duration: 1 },
      { type: "shine", width: 0.3, intensity: 0.8, delay: 1, duration: 1 },
    ]);
    const { svg } = documentSvg(document, new Map());
    expect(svg.startsWith("<svg")).toBe(true);
    expect(svg.endsWith("</svg>")).toBe(true);
    expect(svg).toContain("<mask");
    expect(svg).toContain("linearGradient");
    // Ids must be unique, or one layer's gradient would silently paint another's.
    const ids = [...svg.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("escapes text so a layer cannot break the document", () => {
    const document = applyStickerOperationsV1(fixture(), [
      {
        op: "addLayer",
        layer: {
          id: "hostile",
          name: "Hostile",
          hidden: false,
          anchor: {
            position: { x: 0.5, y: 0.5 }, scale: { x: 0.5, y: 0.5 },
            rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 },
          },
          blendMode: "normal",
          type: "text",
          text: '</text><script>x</script>',
          font: "system",
          weight: "bold",
          paint: { type: "solid", color: "#FFFFFF" },
          alignment: "center",
          animations: [],
          animation: {
            position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
          },
        },
      } as never,
    ]);
    const { svg } = documentSvg(document, new Map());
    expect(svg).not.toContain("<script>");
    expect(svg).toContain("&lt;script&gt;");
  });
});
