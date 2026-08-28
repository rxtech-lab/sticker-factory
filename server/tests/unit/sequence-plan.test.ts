import { describe, expect, it } from "vitest";
import {
  assertAnimatedPlanUsesReferenceBackedArtwork,
  assertPlanReuseIsResolvable,
  planGenerationCount,
  planRequiresConcept,
  PlanV1Schema,
  reusableAssetIds,
  type PlanV1,
} from "@/lib/contracts/plan";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import v3Fixture from "@/fixtures/sticker-document-v3.json";

const ATLAS = "33333333-3333-4333-8333-333333333333";

const captureLayer = (overrides: Record<string, unknown> = {}) => ({
  layerId: "hero",
  name: "Live capture",
  source: { kind: "sequence", assetId: ATLAS, columns: 4, rows: 3, frameCount: 12, frameRate: 10 },
  x: 0.5,
  y: 0.5,
  scaleX: 0.9,
  scaleY: 0.9,
  ...overrides,
});

const plan = (layers: unknown[], kind: "static" | "animated" = "animated"): PlanV1 => PlanV1Schema.parse({
  title: "Me, waving",
  summary: "Your wave, with sparkles.",
  kind,
  timing: { durationSeconds: 1.2, fps: 30, loop: "pingPong" },
  layers,
});

describe("the sequence plan source", () => {
  it("parses and defaults playback to ping-pong", () => {
    // Ping-pong is the default because 1.2s of Live Photo read back and forth is a seamless cycle,
    // where a plain loop cuts hard from the last frame to the first.
    const parsed = plan([captureLayer()]);
    expect(parsed.layers[0].source).toMatchObject({ kind: "sequence", playback: "pingPong" });
  });

  it("costs nothing to generate", () => {
    expect(planGenerationCount(plan([captureLayer()]))).toBe(0);
  });

  it("rejects a grid that cannot hold the frames it declares", () => {
    expect(() => plan([captureLayer({
      source: { kind: "sequence", assetId: ATLAS, columns: 2, rows: 2, frameCount: 12, frameRate: 10 },
    })])).toThrow();
  });
});

describe("animated fidelity", () => {
  const particle = {
    layerId: "spark",
    name: "Spark",
    source: { kind: "particle", preset: "sparkles", color: "#FFD166" },
    x: 0.7,
    y: 0.3,
    scaleX: 0.3,
    scaleY: 0.3,
  };

  it("still refuses app-rendered primitives in an ordinary animated plan", () => {
    const generated = {
      layerId: "hero",
      name: "Hero",
      source: { kind: "generate", prompt: "a cat" },
      x: 0.5,
      y: 0.5,
      scaleX: 0.9,
      scaleY: 0.9,
    };
    expect(() => assertAnimatedPlanUsesReferenceBackedArtwork(plan([generated, particle])))
      .toThrow(/app-rendered primitives/);
  });

  it("allows them around a capture", () => {
    // The rule exists so animated artwork matches an approved generated still. A capture has no
    // such still — it is the reference — and decorating it is the whole point of the feature.
    expect(() => assertAnimatedPlanUsesReferenceBackedArtwork(plan([captureLayer(), particle])))
      .not.toThrow();
  });
});

describe("planRequiresConcept", () => {
  const generated = {
    layerId: "hat",
    name: "Hat",
    source: { kind: "generate", prompt: "a party hat" },
    x: 0.5,
    y: 0.2,
    scaleX: 0.4,
    scaleY: 0.4,
  };

  it("is false for a capture-led plan that draws nothing", () => {
    expect(planRequiresConcept(plan([captureLayer()]))).toBe(false);
  });

  it("is true for a capture-led plan that also draws something", () => {
    // The generated hat does need an approved still to match, so the concept still earns its cost.
    expect(planRequiresConcept(plan([captureLayer(), generated]))).toBe(true);
  });

  it("is true for an ordinary animated plan, including one made only of reused artwork", () => {
    // Unchanged behaviour: the concept doubles as the plan card's preview, and removing it from
    // reuse-only revisions would be a silent regression unrelated to captures.
    const existing = {
      layerId: "old",
      name: "Old",
      source: { kind: "existing", assetId: "11111111-1111-4111-8111-111111111111" },
      x: 0.5,
      y: 0.5,
      scaleX: 0.9,
      scaleY: 0.9,
    };
    expect(planRequiresConcept(plan([existing]))).toBe(true);
    expect(planRequiresConcept(plan([generated]))).toBe(true);
  });

  it("is false for any static plan", () => {
    expect(planRequiresConcept(plan([captureLayer()], "static"))).toBe(false);
  });
});

describe("resolving a planned capture", () => {
  it("accepts one attached to this turn, which is not in the document yet", () => {
    expect(() => assertPlanReuseIsResolvable(plan([captureLayer()]), undefined, [ATLAS])).not.toThrow();
  });

  it("accepts one the sticker already carries", () => {
    const document = StickerDocumentSchema.parse(v3Fixture);
    expect(() => assertPlanReuseIsResolvable(plan([captureLayer()]), document)).not.toThrow();
  });

  it("refuses an id the model made up", () => {
    // Caught here, as a repairable tool error in the same conversation, rather than at build time
    // after the user has already confirmed the plan.
    expect(() => assertPlanReuseIsResolvable(plan([captureLayer()]), undefined, []))
      .toThrow(/does not have|does not exist/);
  });

  it("lists a capture among the artwork a re-plan may reuse", () => {
    const document = StickerDocumentSchema.parse(v3Fixture);
    // Footage cannot be regenerated at any price, so a re-plan that dropped it would replace the
    // user's own face with something drawn from a prompt.
    expect(reusableAssetIds(document)).toContain(ATLAS);
  });
});
