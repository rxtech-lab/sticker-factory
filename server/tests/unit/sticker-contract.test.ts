import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/sticker-document-v1.json";
import { compileLayerAnimation } from "@/lib/animation/compile";
import {
  applyStickerOperationsV1,
  StickerDocumentV1Schema,
  type StickerDocumentV1,
} from "@/lib/contracts/sticker";

describe("StickerDocumentV1", () => {
  it("validates the shared fixture and applies safe operations", () => {
    const source = StickerDocumentV1Schema.parse(fixture);
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

  it("rejects executable or URL-shaped layer payloads", () => {
    expect(() => StickerDocumentV1Schema.parse({
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
    expect(() => StickerDocumentV1Schema.parse(invalid)).toThrow(/beyond durationSeconds/);
  });
});

describe("declarative animations on a document", () => {
  const base = () => StickerDocumentV1Schema.parse(fixture) as StickerDocumentV1;

  it("defaults existing documents to no specs and the resting anchor", () => {
    const document = base();
    expect(document.layers[0].animations).toEqual([]);
    expect(document.layers[0].anchor).toEqual({
      position: { x: 0.5, y: 0.5 },
      scale: { x: 1, y: 1 },
      rotationDegrees: 0,
      opacity: 1,
    });
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
    expect(() => StickerDocumentV1Schema.parse(tampered)).toThrow(/do not match its animations/);
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
