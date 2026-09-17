import { describe, expect, it } from "vitest";
import { GET } from "@/app/api/v1/configuration-limits/route";
import {
  CONFIGURATION_LIMITS,
  MAX_CONTROLS,
  MAX_VARIANTS,
  StickerConfigurationSchema,
  configurationIssues,
  type StickerConfiguration,
} from "@/lib/contracts/configuration";
import { MAX_PLAN_LAYERS } from "@/lib/contracts/plan";

/**
 * One family of two four-option controls, bound to `layerCount` layers.
 *
 * Sixteen rows of a complete table, each patching every layer, is sixteen states per layer — so
 * the prepared total is `16 * layerCount` and the per-layer count stays at sixteen however wide
 * the cast gets. That is the only shape that can walk up to the total cap without tripping the
 * per-layer one first.
 */
function cast(layerCount: number): { configuration: StickerConfiguration; layerIds: Set<string> } {
  const ids = Array.from({ length: layerCount }, (_, index) => `layer_${index}`);
  const options = ["a", "b", "c", "d"].map((id) => ({ id, label: id.toUpperCase() }));
  const variants = options.flatMap((pose) => options.map((mood) => ({
    id: `v_${pose.id}_${mood.id}`,
    selections: { pose: pose.id, mood: mood.id },
    layers: ids.map((layerId) => ({ layerId, text: `${pose.id}${mood.id}` })),
  })));
  return {
    configuration: StickerConfigurationSchema.parse({
      controls: [
        { id: "pose", label: "Pose", type: "choice", defaultValue: "a", options },
        { id: "mood", label: "Mood", type: "choice", defaultValue: "a", options },
      ],
      variants,
    }),
    layerIds: new Set(ids),
  };
}

describe("configuration limits", () => {
  it("serves every number the editor needs, and nothing it cannot act on", async () => {
    const limits = await GET().json();
    expect(limits).toEqual({ ...CONFIGURATION_LIMITS, planLayers: MAX_PLAN_LAYERS });
    // The app disables buttons from these, so a zero or inverted cap would grey out the screen.
    for (const value of Object.values(limits)) expect(value).toBeGreaterThan(0);
    expect(limits.controlOptionsMinimum).toBeLessThanOrEqual(limits.controlOptions);
  });

  it("refuses exactly where the served prepared-state cap says it will", () => {
    const perLayer = 16;
    const atCap = cast(CONFIGURATION_LIMITS.preparedStates / perLayer);
    expect(configurationIssues(atCap.configuration, atCap.layerIds)).toEqual([]);

    const overCap = cast(CONFIGURATION_LIMITS.preparedStates / perLayer + 1);
    expect(configurationIssues(overCap.configuration, overCap.layerIds)).toEqual([
      expect.stringContaining(`At most ${CONFIGURATION_LIMITS.preparedStates} states in total`),
    ]);
  });

  it("serves the caps the schema itself enforces, so the app cannot be told a looser number", () => {
    const { configuration } = cast(1);
    const controls = Array.from({ length: MAX_CONTROLS + 1 }, (_, index) => ({
      id: `speed_${index}`, label: "Speed", type: "number" as const,
      binding: "speed" as const, defaultValue: 1, minimum: 0.25, maximum: 2, step: 0.05,
    }));
    expect(StickerConfigurationSchema.safeParse({ ...configuration, controls }).success).toBe(false);
    expect(CONFIGURATION_LIMITS.controls).toBe(MAX_CONTROLS);

    const variants = Array.from({ length: MAX_VARIANTS + 1 }, (_, index) => configuration.variants[0] && {
      ...configuration.variants[0], id: `extra_${index}`,
    });
    expect(StickerConfigurationSchema.safeParse({ ...configuration, variants }).success).toBe(false);
    expect(CONFIGURATION_LIMITS.variants).toBe(MAX_VARIANTS);
  });
});
