import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  assertAnimatedPlanUsesReferenceBackedArtwork,
  assertPlanAllowedForJob,
  compilePlanAnimations,
  planGenerationCount,
  planLayerAnchor,
  planVideoCount,
  PlanV1Schema,
  withoutLayerTravel,
} from "@/lib/contracts/plan";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
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
    const layers = Array.from({ length: 13 }, (_, index) => ({
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

  it("requires animated visual elements to be image-generated from the approved reference", () => {
    const animated = PlanV1Schema.parse(plan({
      layers: [
        { ...plan().layers[0], source: { kind: "text", text: "OBJECTION!", color: "#FFF8E7" } },
        { ...plan().layers[1], source: { kind: "shape", shape: "burst", fill: "#E31E2B" } },
      ],
    }));
    expect(() => assertAnimatedPlanUsesReferenceBackedArtwork(animated)).toThrow(/part_0 \(text\).*part_1 \(shape\)/);

    const staticPlan = PlanV1Schema.parse({ ...animated, kind: "static", timing: undefined, layers: animated.layers.map((layer) => ({
      ...layer,
      animations: [],
    })) });
    expect(() => assertAnimatedPlanUsesReferenceBackedArtwork(staticPlan)).not.toThrow();
  });
});

describe("video layer sources", () => {
  const clip = { kind: "video", prompt: "A corgi sticker", motion: "A slow full turnaround", durationSeconds: 3 };
  const withClip = (overrides: Record<string, unknown> = {}) => plan({
    summary: "The corgi is generated as a video so it can turn all the way round.",
    layers: [{ ...plan().layers[0], source: clip }, plan().layers[1]],
    ...overrides,
  });

  it("accepts one clip in an animated plan and defaults its length", () => {
    const parsed = PlanV1Schema.parse(withClip({
      layers: [{ ...plan().layers[0], source: { kind: "video", prompt: "A corgi", motion: "spins" } }],
    }));
    expect(parsed.layers[0].source).toMatchObject({ kind: "video", durationSeconds: 3 });
  });

  it("counts the clip's still as a generation and the clip as a video", () => {
    const parsed = PlanV1Schema.parse(withClip());
    expect(planGenerationCount(parsed)).toBe(2);
    expect(planVideoCount(parsed)).toBe(1);
    expect(planVideoCount(PlanV1Schema.parse(plan()))).toBe(0);
  });

  it("refuses a clip in a static plan", () => {
    const result = PlanV1Schema.safeParse(withClip({ kind: "static", timing: undefined }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/needs an animated plan/);
  });

  it("refuses more than one clip", () => {
    const result = PlanV1Schema.safeParse(withClip({
      layers: [{ ...plan().layers[0], source: clip }, { ...plan().layers[1], source: clip }],
    }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/At most one video layer/);
  });

  it("keeps the clip inside the video model's and the plan timing's bounds", () => {
    expect(PlanV1Schema.safeParse(withClip({
      layers: [{ ...plan().layers[0], source: { ...clip, durationSeconds: 5 } }],
    })).success).toBe(false);
    expect(PlanV1Schema.safeParse(withClip({
      layers: [{ ...plan().layers[0], source: { ...clip, durationSeconds: 1 } }],
    })).success).toBe(false);
  });

  it("makes the summary tell the user which layer is a video", () => {
    const result = PlanV1Schema.safeParse(withClip({ summary: "The corgi turns around. Confirm to build it." }));
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error?.issues)).toMatch(/Say in the summary which layer/);
  });

  it("is reference-backed, so the animated fidelity rule leaves it alone", () => {
    expect(() => assertAnimatedPlanUsesReferenceBackedArtwork(PlanV1Schema.parse(withClip()))).not.toThrow();
  });

  it("is refused for a quick turn, which is rendered where a clip cannot play", () => {
    const parsed = PlanV1Schema.parse(withClip());
    expect(() => assertPlanAllowedForJob(parsed, { quick: true })).toThrow(/not available in quick mode.*part_0/);
    expect(() => assertPlanAllowedForJob(parsed, { quick: false })).not.toThrow();
    expect(() => assertPlanAllowedForJob(PlanV1Schema.parse(plan()), { quick: true })).not.toThrow();
  });

  it("is aspect-locked like every other pixel-backed layer", () => {
    const parsed = PlanV1Schema.parse(withClip());
    expect(planLayerAnchor(parsed.layers[0]).scale).toEqual({ x: 0.4, y: 0.4 });
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
    // The anchor gained a resting trim window in v2. A plan never trims — draw-on is authored as a
    // spec — so a planned layer always starts out showing its whole path. The scale is square
    // rather than the authored 0.4 x 0.6 because this layer's artwork is pixels; see below.
    expect(planLayerAnchor(parsed.layers[0])).toEqual({
      trim: { start: 0, end: 1 },
      position: { x: 0.3, y: 0.5 },
      scale: { x: 0.4, y: 0.4 },
      rotationDegrees: 0,
      opacity: 1,
    });
  });

  // Both renderers draw a layer into a square box and then apply the anchor's scale as a plain
  // `scale(x, y)`, so a wide box used to stretch the square PNG behind a generated layer — which is
  // what turned an approved title into a squashed banner. Fitting the artwork inside the planned
  // box is the only reading that leaves it undistorted, and it can only shrink a layer, so a layout
  // that passed the overlap and off-canvas checks still passes.
  it("squares off the scale of a layer whose artwork is pixels", () => {
    const parsed = PlanV1Schema.parse(plan());
    expect(planLayerAnchor(parsed.layers[0]).scale).toEqual({ x: 0.4, y: 0.4 });
  });

  // Glyphs are fitted inside their box by the renderer, so a wide text box is a small square of
  // letters; squaring it here keeps the plan's footprint honest about that.
  it("squares a text layer off like pixel artwork", () => {
    const parsed = PlanV1Schema.parse(plan({
      kind: "static",
      layers: [{ ...plan().layers[0], animations: [], source: { kind: "text", text: "HI", color: "#FF0055" } }],
    }));
    expect(planLayerAnchor(parsed.layers[0]).scale).toEqual({ x: 0.4, y: 0.4 });
  });

  it("leaves an app-drawn layer free to occupy a non-square box", () => {
    for (const source of [
      { kind: "shape", shape: "roundedRectangle", fill: "#FF8800" },
      { kind: "particle", preset: "sparkles", color: "#FFD400" },
    ]) {
      const parsed = PlanV1Schema.parse(plan({
        kind: "static",
        layers: [{ ...plan().layers[0], animations: [], source }],
      }));
      expect(planLayerAnchor(parsed.layers[0]).scale).toEqual({ x: 0.4, y: 0.6 });
    }
  });
});

describe("planned layout compiles into a valid document", () => {
  function documentFrom(kind: "static" | "animated") {
    const parsed = PlanV1Schema.parse(plan({ kind }));
    const compiled = compilePlanAnimations(parsed);
    return StickerDocumentSchema.parse({
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

describe("stripping travel from a sticker asked to hold still", () => {
  const moving = () => PlanV1Schema.parse(plan({
    layers: [
      {
        layerId: "part_0",
        name: "Plane",
        source: { kind: "generate", prompt: "A plane" },
        x: 0.5, y: 0.5, scaleX: 0.6, scaleY: 0.6,
        animations: [
          { type: "float", amplitude: 0.04, cycles: 2, duration: 2 },
          { type: "wiggle", amplitudeDegrees: 8, cycles: 3, duration: 1 },
          { type: "fadeIn", duration: 0.3 },
        ],
      },
    ],
  }));

  it("removes drift and absolute moves but keeps acting in place", () => {
    const still = withoutLayerTravel(moving());
    expect(still.layers[0].animations.map((animation) => animation.type)).toEqual(["wiggle", "fadeIn"]);
  });

  it("leaves a plan that was already still untouched", () => {
    const already = PlanV1Schema.parse(plan());
    expect(withoutLayerTravel(already)).toEqual(already);
  });

  it("strips the same motion from configurable variants", () => {
    const configured = PlanV1Schema.parse(plan({
      configuration: {
        controls: [{
          id: "pose", label: "Pose", type: "choice", defaultValue: "rest",
          options: [{ id: "rest", label: "Rest" }, { id: "wave", label: "Wave" }],
        }],
        variants: [
          {
            id: "rest",
            selections: { pose: "rest" },
            layers: [{
              layerId: "part_0",
              animations: [
                { type: "bounce", height: 0.12, bounces: 2, duration: 1 },
                { type: "pulse", minScale: 0.92, maxScale: 1.08, cycles: 2, duration: 1 },
              ],
            }],
          },
          {
            id: "wave",
            selections: { pose: "wave" },
            layers: [{
              layerId: "part_0",
              animations: [{ type: "wiggle", amplitudeDegrees: 8, cycles: 3, duration: 1 }],
            }],
          },
        ],
      },
    }));
    const still = withoutLayerTravel(configured);
    expect(still.configuration!.variants[0].layers[0].animations!.map((a) => a.type)).toEqual(["pulse"]);
  });
});
