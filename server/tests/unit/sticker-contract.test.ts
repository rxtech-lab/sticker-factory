import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/sticker-document-v1.json";
import { compileLayerAnimation } from "@/lib/animation/compile";
import { MAX_LAYER_INDEX,
  applyStickerOperationsV1,
  CURRENT_DOCUMENT_VERSION,
  StickerDocumentSchema,
  type StickerDocument,
} from "@/lib/contracts/sticker";

describe("StickerDocument", () => {
  it("validates the shared fixture and applies safe operations", () => {
    const source = StickerDocumentSchema.parse(fixture);
    const result = applyStickerOperationsV1(source, [
      {
        op: "setRotationKeyframes",
        layerId: "hero",
        keyframes: [
          { timeSeconds: 0, degrees: -8, easing: "easeOut" },
          { timeSeconds: 2, degrees: 8, easing: "easeIn" },
        ],
      },
    ]);

    expect(result.layers[0].animation.rotation).toHaveLength(2);
    expect(source.layers[0].animation.rotation).toHaveLength(0);
  });

  // The layers array is unbounded, so a document grown past eight layers by edits has to remain
  // reorderable to its top; the cap is a sanity bound on model output, not a stack height.
  it("reorders and inserts past the plan's eight layers, up to the operation index cap", () => {
    const source = StickerDocumentSchema.parse(fixture);
    const result = applyStickerOperationsV1(source, [
      { op: "reorderLayer", layerId: source.layers[0].id, index: 20 },
    ]);
    expect(result.layers.at(-1)?.id).toBe(source.layers[0].id);
    expect(() => applyStickerOperationsV1(source, [
      { op: "reorderLayer", layerId: source.layers[0].id, index: MAX_LAYER_INDEX + 1 },
    ])).toThrow();
  });

  it("rejects executable or URL-shaped layer payloads", () => {
    expect(() => StickerDocumentSchema.parse({
      ...fixture,
      layers: [{ type: "javascript", source: "alert(1)" }],
    })).toThrow();
  });

  it("rejects keyframes beyond the absolute duration", () => {
    const invalid = {
      ...structuredClone(fixture),
      layers: [{
        ...structuredClone(fixture.layers[0]),
        animation: {
          ...structuredClone(fixture.layers[0].animation),
          opacity: [{ timeSeconds: 3, value: 1, easing: "linear" }],
        },
      }],
    };
    expect(() => StickerDocumentSchema.parse(invalid)).toThrow(/beyond durationSeconds/);
  });
});

describe("declarative animations on a document", () => {
  const base = () => StickerDocumentSchema.parse(fixture) as StickerDocument;

  it("defaults existing documents to no specs and the resting anchor", () => {
    const document = base();
    expect(document.layers[0].animations).toEqual([]);
    expect(document.layers[0].anchor).toEqual({
      position: { x: 0.5, y: 0.5 },
      scale: { x: 1, y: 1 },
      rotationDegrees: 0,
      opacity: 1,
      // Added in v2 with the trim channel. It defaults to the whole path, so a stored anchor that
      // predates the field reads back as untrimmed rather than invisible.
      trim: { start: 0, end: 1 },
    });
    expect(document.layers[0].animation.trim).toEqual([]);
  });

  it("compiles keyframes from setLayerAnimations", () => {
    const result = applyStickerOperationsV1(base(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [{ type: "popIn", delay: 0.2, duration: 0.4, easing: "springBouncy" }],
    }]);
    const layer = result.layers[0];
    expect(layer.animations).toHaveLength(1);
    expect(layer.animation.scale.map((frame) => frame.timeSeconds)).toEqual([0.2, 0.6]);
    expect(layer.animation).toEqual(
      compileLayerAnimation(layer.animations, layer.anchor, { kind: result.kind, durationSeconds: result.durationSeconds }),
    );
  });

  it("moves the layer when an anchor accompanies the animations", () => {
    const result = applyStickerOperationsV1(base(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [],
      anchor: { position: { x: 0.25, y: 0.4 }, scale: { x: 0.5, y: 0.5 }, rotationDegrees: 0, opacity: 1 },
    }]);
    expect(result.layers[0].animation.position).toEqual([
      { timeSeconds: 0, x: 0.25, y: 0.4, easing: "linear" },
    ]);
  });

  it("rejects a document whose compiled keyframes contradict its specs", () => {
    const document = applyStickerOperationsV1(base(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [{ type: "fadeIn", delay: 0, duration: 0.5 }],
    }]);
    const tampered = structuredClone(document);
    tampered.layers[0].animation.opacity[1].value = 0.25;
    expect(() => StickerDocumentSchema.parse(tampered)).toThrow(/do not match its animations/);
  });

  it("refuses to hand-edit a channel owned by specs", () => {
    const document = applyStickerOperationsV1(base(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [{ type: "fadeIn", delay: 0, duration: 0.5 }],
    }]);
    expect(() => applyStickerOperationsV1(document, [{
      op: "setOpacityKeyframes",
      layerId: "hero",
      keyframes: [{ timeSeconds: 0, value: 1, easing: "linear" }],
    }])).toThrow(/animated declaratively/);
  });

  it("still allows hand-authored keyframes on a layer with no specs", () => {
    const result = applyStickerOperationsV1(base(), [{
      op: "setOpacityKeyframes",
      layerId: "hero",
      keyframes: [{ timeSeconds: 0, value: 0.5, easing: "linear" }],
    }]);
    expect(result.layers[0].animation.opacity).toHaveLength(1);
  });

  it("recompiles specs when the duration changes", () => {
    const document = applyStickerOperationsV1(base(), [{
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [{ type: "wiggle", delay: 0, duration: 2, cycles: 2 }],
    }]);
    expect(document.layers[0].animation.rotation.at(-1)?.timeSeconds).toBe(2);

    // Shrinking the sticker below the spec's window must fail rather than silently leave keyframes
    // stranded past the end of the timeline.
    expect(() => applyStickerOperationsV1(document, [{
      op: "setTiming", durationSeconds: 1, fps: 30, loop: "loop",
    }])).toThrow(/only 1s long/);
  });
});

describe("v1 documents upcast to the current version on read", () => {
  /**
   * `document_json` is immutable after insert, so stored revisions stay v1 forever and this path
   * is permanent code rather than a migration step. `getSticker` also re-parses *every* revision of
   * a sticker on read, so one row that failed to upcast would take out the whole detail endpoint —
   * which is why totality matters more here than anywhere else in the contract.
   *
   * Since v3 the chain is two hops, v1 -> v2 -> v3, so this also covers the v1 upcast still landing
   * on a shape the v2 schema accepts rather than on whatever is current.
   */
  it("accepts the stored v1 fixture and restamps it", () => {
    const document = StickerDocumentSchema.parse(fixture);
    expect(document.version).toBe(CURRENT_DOCUMENT_VERSION);
    expect(document.speed).toBe(1);
    expect(document.background).toEqual({ type: "none" });
    expect(document.layers[0].blendMode).toBe("normal");
  });

  it("turns v1's bare hex colours into solid paints", () => {
    const document = StickerDocumentSchema.parse({
      ...structuredClone(fixture),
      layers: [
        { id: "cap", name: "Cap", type: "text", text: "Hi", font: "rounded", weight: "bold", color: "#FF0055" },
        { id: "dot", name: "Dot", type: "shape", shape: "circle", fill: "#00FF00", stroke: "#0000FF", strokeWidth: 0.02 },
        { id: "spark", name: "Spark", type: "particle", preset: "sparkles", count: 8, color: "#FFCC00", seed: 3 },
      ],
    });
    const [text, shape, particle] = document.layers;
    if (text.type !== "text" || shape.type !== "shape" || particle.type !== "particle") {
      throw new Error("upcast changed the layer kinds");
    }
    expect(text.paint).toEqual({ type: "solid", color: "#FF0055" });
    expect(particle.paint).toEqual({ type: "solid", color: "#FFCC00" });
    expect(shape.fill).toEqual({ type: "solid", color: "#00FF00" });
    expect(shape.shape).toEqual({ kind: "circle" });
    expect(shape.stroke).toMatchObject({ paint: { type: "solid", color: "#0000FF" }, width: 0.02 });
  });

  /** A zero stroke width was v1's way of saying "no stroke", not "a hairline one". */
  it("drops a v1 stroke whose width was zero", () => {
    const document = StickerDocumentSchema.parse({
      ...structuredClone(fixture),
      layers: [{ id: "dot", name: "Dot", type: "shape", shape: "circle", fill: "#00FF00", stroke: "#0000FF", strokeWidth: 0 }],
    });
    const shape = document.layers[0];
    if (shape.type !== "shape") throw new Error("upcast changed the layer kind");
    expect(shape.stroke).toBeUndefined();
  });

  it("gives v1's hard-coded star its five points", () => {
    const document = StickerDocumentSchema.parse({
      ...structuredClone(fixture),
      layers: [{ id: "s", name: "S", type: "shape", shape: "star", fill: "#FFFFFF" }],
    });
    const shape = document.layers[0];
    if (shape.type !== "shape") throw new Error("upcast changed the layer kind");
    expect(shape.shape).toEqual({ kind: "star", points: 5, innerRatio: 0.42 });
  });

  it("is idempotent: upcast output parses again unchanged", () => {
    const once = StickerDocumentSchema.parse(fixture);
    expect(StickerDocumentSchema.parse(once)).toEqual(once);
  });
});

describe("v2 widening", () => {
  const v2 = (overrides: Record<string, unknown>) => StickerDocumentSchema.parse({
    ...structuredClone(StickerDocumentSchema.parse(fixture)),
    ...overrides,
  });

  it("accepts a canvas that is neither square nor 1024", () => {
    const document = v2({ canvas: { width: 512, height: 192, coordinateSpace: "normalized", transparent: true } });
    expect(document.canvas).toMatchObject({ width: 512, height: 192 });
  });

  it("rejects a canvas outside the supported range", () => {
    expect(() => v2({ canvas: { width: 4, height: 4, coordinateSpace: "normalized", transparent: true } })).toThrow();
    expect(() => v2({ canvas: { width: 9000, height: 9000, coordinateSpace: "normalized", transparent: true } })).toThrow();
  });

  it("accepts an svg layer with inline markup", () => {
    const document = v2({
      layers: [{
        id: "art", name: "Art", type: "svg",
        source: { kind: "inline", markup: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="M0 0 L10 10"/></svg>' },
      }],
    });
    expect(document.layers[0].type).toBe("svg");
  });

  it("rejects svg markup that would script or fetch", () => {
    const withMarkup = (markup: string) => () => v2({
      layers: [{ id: "art", name: "Art", type: "svg", source: { kind: "inline", markup } }],
    });
    expect(withMarkup("<svg><script>alert(1)</script></svg>")).toThrow(/script/);
    expect(withMarkup('<svg><image href="https://evil.example/x.png"/></svg>')).toThrow(/remote URL/);
    expect(withMarkup("<svg><foreignObject/></svg>")).toThrow(/foreignobject/i);
    // A namespace declaration is not a fetch, and a data URI is self-contained.
    expect(withMarkup('<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AA"/></svg>')).not.toThrow();
  });

  it("accepts a gradient fill and rejects a one-stop gradient", () => {
    const gradient = (stops: unknown[]) => () => v2({
      layers: [{
        id: "dot", name: "Dot", type: "shape", shape: { kind: "circle" },
        fill: { type: "linearGradient", stops, angleDegrees: 45 },
      }],
    });
    expect(gradient([{ color: "#FF0000", location: 0 }, { color: "#0000FF", location: 1 }])).not.toThrow();
    expect(gradient([{ color: "#FF0000", location: 0 }])).toThrow();
  });

  it("rejects a shape with neither fill nor stroke, which would draw nothing", () => {
    expect(() => v2({
      layers: [{ id: "dot", name: "Dot", type: "shape", shape: { kind: "circle" } }],
    })).toThrow(/needs a fill or a stroke/);
  });

  it("carries speed without touching keyframes", () => {
    const document = v2({ speed: 2.5 });
    if (document.kind !== "animated") throw new Error("fixture is not animated");
    expect(document.speed).toBe(2.5);
    expect(document.layers[0].animation).toEqual(StickerDocumentSchema.parse(fixture).layers[0].animation);
  });
});

describe("document size budget", () => {
  /**
   * Only reachable through inline SVG: every other field is bounded by its own schema. Twelve
   * layers at the 200 KB per-layer markup cap is 2.4 MB, which `readJson` (1 MB) would refuse and
   * which would also land verbatim in an idempotency response row.
   */
  it("rejects a document that is individually valid but collectively too large", () => {
    const filler = "M0 0 L1 1 ".repeat(9000);
    const layer = (id: string) => ({
      id, name: id, type: "svg",
      source: { kind: "inline", markup: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><path d="${filler}"/></svg>` },
    });
    const base = structuredClone(StickerDocumentSchema.parse(fixture));

    // One such layer is fine — the per-layer cap has room for it.
    expect(() => StickerDocumentSchema.parse({ ...base, layers: [layer("a")] })).not.toThrow();
    // Enough of them is not, even though each one passes on its own.
    expect(() => StickerDocumentSchema.parse({
      ...base,
      layers: ["a", "b", "c", "d", "e", "f"].map(layer),
    })).toThrow(/over the .*-byte limit/);
  });
});
