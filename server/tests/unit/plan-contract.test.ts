import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  compilePlanAnimations,
  planGenerationCount,
  planLayerAnchor,
  PlanV1Schema,
} from "@/lib/contracts/plan";
import { StickerDocumentV1Schema } from "@/lib/contracts/sticker";
import { derivedAssetId } from "@/lib/services/assets";

const uuid = z.string().uuid();

function plan(overrides: Record<string, unknown> = {}) {
  return {
    version: 1,
    title: "Typewriter HI",
    summary: "Two letters revealed in order.",
    kind: "animated",
    timing: { durationSeconds: 2, fps: 30, loop: "loop" },
    layers: [
      {
        layerId: "part_0",
        name: "H",
        source: { kind: "generate", prompt: "The letter H" },
        x: 0.3, y: 0.5, scaleX: 0.4, scaleY: 0.6,
      },
      {
        layerId: "part_1",
        name: "I",
        source: { kind: "generate", prompt: "The letter I" },
        x: 0.7, y: 0.5, scaleX: 0.4, scaleY: 0.6,
      },
    ],
    ...overrides,
  };
}

describe("derivedAssetId", () => {
  it("is stable for the same job and index", () => {
    expect(derivedAssetId("job-1", 0)).toBe(derivedAssetId("job-1", 0));
  });

  it("differs per index and per job", () => {
    expect(derivedAssetId("job-1", 0)).not.toBe(derivedAssetId("job-1", 1));
    expect(derivedAssetId("job-1", 0)).not.toBe(derivedAssetId("job-2", 0));
  });

  it("produces version-4 UUIDs both ends accept", () => {
    for (let index = 0; index < 8; index += 1) {
      const value = derivedAssetId("job-1", index);
      expect(uuid.safeParse(value).success).toBe(true);
      expect(value[14]).toBe("4");
      expect("89ab").toContain(value[19]);
    }
  });
});

describe("PlanV1Schema", () => {
  it("accepts a two-layer plan", () => {
    expect(PlanV1Schema.parse(plan()).layers).toHaveLength(2);
  });

  it("accepts a single layer, since a plan is now a general design not a multi-image signal", () => {
    expect(PlanV1Schema.safeParse(plan({ layers: [plan().layers[0]] })).success).toBe(true);
  });

  it("rejects more layers than the document layer ceiling", () => {
    const layers = Array.from({ length: 9 }, (_, index) => ({
      ...plan().layers[0],
      layerId: `part_${index}`,
    }));
    expect(PlanV1Schema.safeParse(plan({ layers })).success).toBe(false);
  });

  it("rejects duplicate layer ids", () => {
    const layers = [plan().layers[0], { ...plan().layers[1], layerId: "part_0" }];
    expect(PlanV1Schema.safeParse(plan({ layers })).success).toBe(false);
  });

  it("keeps layers on canvas", () => {
    expect(PlanV1Schema.safeParse(plan({
      layers: [{ ...plan().layers[0], x: 1.5 }, plan().layers[1]],
    })).success).toBe(false);
  });

  it("supports non-image layer sources", () => {
    const parsed = PlanV1Schema.parse(plan({
      layers: [
        { ...plan().layers[0], source: { kind: "text", text: "HI", color: "#FF00AA" } },
        { ...plan().layers[1], source: { kind: "particle", preset: "sparkles", color: "#FFDD00" } },
      ],
    }));
    expect(parsed.layers[0].source).toMatchObject({ kind: "text", font: "rounded", weight: "bold" });
    expect(parsed.layers[1].source).toMatchObject({ kind: "particle", count: 24 });
  });

  it("only counts generate layers as image generations", () => {
    const parsed = PlanV1Schema.parse(plan({
      layers: [
        plan().layers[0],
        { ...plan().layers[1], source: { kind: "shape", shape: "star", fill: "#FF0000" } },
      ],
    }));
    expect(planGenerationCount(parsed)).toBe(1);
  });
});

describe("plan animations", () => {
  it("rejects a plan whose motion runs past the sticker duration", () => {
    const result = PlanV1Schema.safeParse(plan({
      timing: { durationSeconds: 1, fps: 30, loop: "loop" },
      layers: [{
        ...plan().layers[0],
        animations: [{ type: "fadeIn", delay: 0.8, duration: 0.5 }],
      }],
    }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/only 1s long/);
  });

  it("rejects a plan with conflicting motion on one channel", () => {
    const result = PlanV1Schema.safeParse(plan({
      layers: [{
        ...plan().layers[0],
        animations: [
          { type: "fadeIn", delay: 0, duration: 1 },
          { type: "fadeOut", delay: 0.5, duration: 1 },
        ],
      }],
    }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/both drive the opacity channel/);
  });

  it("rejects animating a static plan", () => {
    const result = PlanV1Schema.safeParse(plan({
      kind: "static",
      layers: [{ ...plan().layers[0], animations: [{ type: "fadeIn", duration: 0.4 }] }],
    }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/static sticker cannot animate/);
  });

  it("staggers a typewriter reveal purely with delays", () => {
    const parsed = PlanV1Schema.parse(plan({
      layers: plan().layers.map((layer, index) => ({
        ...layer,
        animations: [{ type: "popIn", delay: index * 0.3, duration: 0.4, easing: "springBouncy" }],
      })),
    }));
    const compiled = compilePlanAnimations(parsed);
    expect(compiled[0].opacity.map((frame) => frame.timeSeconds)).toEqual([0, 0.4]);
    expect(compiled[1].opacity.map((frame) => frame.timeSeconds)).toEqual([0.3, 0.7]);
  });

  it("derives the anchor from the plan layout", () => {
    const parsed = PlanV1Schema.parse(plan());
    expect(planLayerAnchor(parsed.layers[0])).toEqual({
      position: { x: 0.3, y: 0.5 },
      scale: { x: 0.4, y: 0.6 },
      rotationDegrees: 0,
      opacity: 1,
    });
  });
});

describe("planned layout compiles into a valid document", () => {
  function documentFrom(kind: "static" | "animated") {
    const parsed = PlanV1Schema.parse(plan({ kind }));
    const compiled = compilePlanAnimations(parsed);
    return StickerDocumentV1Schema.parse({
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      mp4Background: { type: "solid", color: "#FFFFFF" },
      kind,
      durationSeconds: kind === "static" ? 0 : parsed.timing.durationSeconds,
      fps: kind === "static" ? 0 : parsed.timing.fps,
      loop: kind === "static" ? "once" : parsed.timing.loop,
      layers: parsed.layers.map((layer, index) => ({
        id: layer.layerId,
        name: layer.name,
        hidden: false,
        type: "image" as const,
        assetId: derivedAssetId("job-1", index),
        contentMode: "fit" as const,
        anchor: planLayerAnchor(layer),
        animations: layer.animations,
        animation: compiled[index],
      })),
    });
  }

  it("is valid for a static document, where keyframes may only sit at t=0", () => {
    const document = documentFrom("static");
    expect(document.layers).toHaveLength(2);
    expect(document.layers[0].animation.position[0].timeSeconds).toBe(0);
    expect(document.layers[0].animation.position[0]).toMatchObject({ x: 0.3, y: 0.5 });
  });

  it("is valid for an animated document", () => {
    expect(documentFrom("animated").layers).toHaveLength(2);
  });
});
