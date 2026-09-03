import { describe, expect, it } from "vitest";
import {
  apiCostNanodollars,
  apiCostPoints,
  estimatedVideoCostUsd,
  gatewayCostUsd,
  recordImageApiCost,
  recordTextApiCost,
  recordVideoApiCost,
  totalApiCostPoints,
  videoPricingTier,
  withAiApiCostRecorder,
  type AiApiCostEvent,
} from "@/lib/ai/cost";

describe("AI API point pricing", () => {
  it("converts 10 USD to 700 points and rounds up to a whole point", () => {
    expect(apiCostPoints(10)).toBe(700);
    expect(apiCostPoints("0.10")).toBe(7);
    expect(apiCostPoints("0.101")).toBe(8);
    expect(apiCostPoints("0.0000001")).toBe(1);
    expect(apiCostPoints(0)).toBe(0);
  });

  it("keeps decimal API cost as integer nanodollars", () => {
    expect(apiCostNanodollars("0.0000672")).toBe(67_200);
    expect(gatewayCostUsd({ gateway: { cost: "0.0000672" } })).toBe("0.0000672");
  });

  it("rounds all text calls up once for the chat turn", () => {
    expect(totalApiCostPoints({
      // Rounded up per call these two $0.004 steps would cost two points; as one
      // $0.008 turn they cost one.
      textCostNanodollars: 8_000_000,
      imagePoints: 0,
    })).toBe(1);
  });

  it("captures every text step and rounds each image up independently", async () => {
    const events: AiApiCostEvent[] = [];
    await withAiApiCostRecorder(async (event) => {
      events.push(event);
    }, async () => {
      await recordTextApiCost({
        steps: [
          { providerMetadata: { gateway: { cost: "0.004" } } },
          { providerMetadata: { gateway: { cost: "0.004" } } },
        ],
      });
      await recordImageApiCost({ providerMetadata: { gateway: { cost: "0.008" } } });
      await recordImageApiCost({ providerMetadata: { gateway: { cost: "0.02" } } });
    });

    expect(events).toEqual([
      { kind: "text", costNanodollars: 8_000_000 },
      { kind: "image", costNanodollars: 8_000_000, points: 1 },
      { kind: "image", costNanodollars: 20_000_000, points: 2 },
    ]);
  });

  it("refuses to silently make a Gateway call free when pricing metadata is missing", async () => {
    await expect(withAiApiCostRecorder(async () => {}, () =>
      recordTextApiCost({ steps: [{ providerMetadata: {} }] }),
    )).rejects.toThrow("did not return API pricing");
  });
});

describe("video pricing", () => {
  const seedance = { modelId: "bytedance/seedance-v1.0-pro-fast", resolution: "480p", durationSeconds: 3 };

  it("adds per-clip points to the turn total without re-rounding them", () => {
    expect(totalApiCostPoints({ textCostNanodollars: 8_000_000, imagePoints: 2, videoPoints: 3 })).toBe(6);
    expect(totalApiCostPoints({ textCostNanodollars: 0, imagePoints: 0 })).toBe(0);
  });

  it("prices a clip by its shorter side whichever way the resolution is spelled", () => {
    expect(videoPricingTier("480p")).toBe("480p");
    expect(videoPricingTier("480x480")).toBe("480p");
    expect(videoPricingTier("1280x720")).toBe("720p");
    expect(estimatedVideoCostUsd(seedance)).toBeCloseTo(0.0291, 6);
    expect(estimatedVideoCostUsd({ ...seedance, resolution: "480x480" })).toBeCloseTo(0.0291, 6);
    expect(estimatedVideoCostUsd({ ...seedance, modelId: "nobody/unknown-video" })).toBeUndefined();
    expect(estimatedVideoCostUsd({ ...seedance, durationSeconds: 0 })).toBeUndefined();
  });

  it("takes the Gateway's charge when it sends one", async () => {
    const events: AiApiCostEvent[] = [];
    let priced: string | undefined;
    await withAiApiCostRecorder(async (event) => { events.push(event); }, async () => {
      priced = await recordVideoApiCost({ providerMetadata: { gateway: { cost: "0.05" } } }, seedance);
    });
    expect(priced).toBe("gateway");
    expect(events).toEqual([{ kind: "video", costNanodollars: 50_000_000, points: 4 }]);
  });

  it("falls back to the list price rather than handing out a free clip", async () => {
    const events: AiApiCostEvent[] = [];
    let priced: string | undefined;
    await withAiApiCostRecorder(async (event) => { events.push(event); }, async () => {
      priced = await recordVideoApiCost({ providerMetadata: {} }, seedance);
    });
    expect(priced).toBe("estimate");
    // 3 s at $0.0097/s is $0.0291, which rounds up to a whole point, as an image would.
    expect(events).toEqual([{ kind: "video", costNanodollars: 29_100_000, points: 3 }]);
  });

  it("refuses a clip whose price is known neither way", async () => {
    await expect(withAiApiCostRecorder(async () => {}, () =>
      recordVideoApiCost({ providerMetadata: {} }, { ...seedance, modelId: "nobody/unknown-video" }),
    )).rejects.toThrow("no list price");
  });

  it("records nothing outside a turn, like the other recorders", async () => {
    await expect(recordVideoApiCost({ providerMetadata: {} }, seedance)).resolves.toBe("unrecorded");
  });
});
