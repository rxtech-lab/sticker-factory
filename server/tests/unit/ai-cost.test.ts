import { describe, expect, it } from "vitest";
import {
  apiCostNanodollars,
  apiCostPoints,
  gatewayCostUsd,
  recordImageApiCost,
  recordTextApiCost,
  totalApiCostPoints,
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
