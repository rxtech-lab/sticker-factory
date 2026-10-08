import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { composeCreditHold, jobCreditHold } from "@/lib/subscription/pricing";
import fixture from "@/fixtures/sticker-document-v5.json";
import { StickerDocumentSchema, applyStickerOperationsV1, downcastForClient, documentRenderableLayers, resolveStickerConfiguration, type StickerOperationV1 } from "@/lib/contracts/sticker";
import { PlanV1Schema, applyPlanEdit, planGenerationCount } from "@/lib/contracts/plan";
import { StickerConfigurationSchema } from "@/lib/contracts/configuration";
import { configurationCoverage, configurationIssueDetails, configurationSelections } from "@/lib/contracts/configuration";
import { validateGeneratedAtlas } from "@/lib/render/sprite-atlas";
import { configurationFromPlan } from "@/workflows/sticker-generation/configurable-artwork";

const document = () => StickerDocumentSchema.parse(fixture);
describe("configurable document v5", () => {
  it("round trips the shared Swift fixture, composing expression and motion independently", () => {
    const source = document();
    expect(StickerDocumentSchema.parse(JSON.parse(JSON.stringify(source)))).toEqual(source);
    expect(configurationSelections(source.configuration!)).toHaveLength(4);
    const result = resolveStickerConfiguration(source, { mood: "sad", pose: "hop", sparkles: false, speed: 2 });
    expect(result.configuration).toBeUndefined();
    expect(result.layers[0]).toMatchObject({ type: "image", assetId: "22222222-2222-4222-8222-222222222222" });
    expect(result.layers[0].animation.position.length).toBeGreaterThan(1);
    expect(result.layers[1].hidden).toBe(true);
    expect(result.speed).toBe(2);
    expect(source.layers[1].hidden).toBe(false);
    expect(documentRenderableLayers(source).some((layer) => layer.type === "image" && layer.assetId.startsWith("2222"))).toBe(true);
  });
  it("uses authored defaults for incompatible selections and bounds speed", () => {
    const result = resolveStickerConfiguration(document(), { mood: "gone", sparkles: "false", speed: 100 });
    expect(result.layers[0]).toMatchObject({ assetId: fixture.layers[0].assetId });
    expect(result.layers[1].hidden).toBe(false);
    expect(result.speed).toBe(2);
  });
  it("serves the resolved authored default to older clients", () => {
    const source = document();
    source.configuration!.controls[0].defaultValue = "sad";
    const legacy = downcastForClient(source, 4);
    expect(legacy).toMatchObject({ version: 4, layers: [{ assetId: "22222222-2222-4222-8222-222222222222" }, {}] });
    expect(legacy).not.toHaveProperty("configuration");
    expect(StickerDocumentSchema.parse(legacy).version).toBe(8);
  });
  it.each(["coverage", "conflict", "asset", "layer", "default"])("rejects invalid %s before rendering", (failure) => {
    const source = structuredClone(fixture);
    if (failure === "coverage") source.configuration.variants.pop();
    if (failure === "conflict") source.configuration.variants[2].layers[0] = { layerId: "hero", source: { kind: "base" } };
    if (failure === "asset") source.configuration.variants[1].layers[0] = { layerId: "hero", source: { kind: "image", assetId: "missing" } };
    if (failure === "layer") source.configuration.variants[0].layers[0].layerId = "missing";
    if (failure === "default") source.configuration.controls[0].defaultValue = "missing";
    expect(StickerDocumentSchema.safeParse(source).success).toBe(false);
  });
  it("requires every combined mood/pose artwork cell, including nondefault combinations", () => {
    const source = document();
    source.configuration!.variants = configurationSelections(source.configuration!).map((values, index) => ({
      id: `combined_${index}`, selections: values as Record<string, string>, layers: [{ layerId: "hero", source: { kind: "base" } }],
    }));
    expect(StickerDocumentSchema.safeParse(source).success).toBe(true);
    source.configuration!.variants.pop();
    expect(StickerDocumentSchema.safeParse(source).success).toBe(false);
  });
  it("removes deleted-layer bindings and orphan choices", () => {
    const result = applyStickerOperationsV1(document(), [{ op: "removeLayer", layerId: "hero" }]);
    expect(result.configuration!.variants).toEqual([]);
    expect(result.configuration!.controls.map((control) => control.id)).toEqual(["sparkles", "speed"]);
  });
  it("resolves option placement before applying its complete stack order", () => {
    const source = document();
    for (const variant of source.configuration!.variants.filter((item) => "mood" in item.selections)) {
      variant.layers[0].anchor = {
        ...source.layers[0].anchor,
        position: { x: variant.id === "sad" ? 0.72 : 0.3, y: 0.4 },
      };
      variant.layerOrder = ["spark", "hero"];
    }
    const parsed = StickerDocumentSchema.parse(source);
    const resolved = resolveStickerConfiguration(parsed, { mood: "sad" });
    expect(resolved.layers.map((layer) => layer.id)).toEqual(["spark", "hero"]);
    expect(resolved.layers[1].anchor.position.x).toBe(0.72);
  });
  it("describes an empty option binding with ids, field, and a correction", () => {
    const configuration = document().configuration!;
    configuration.variants[0].layers[0] = { layerId: "hero" };
    const issue = configurationIssueDetails(configuration, new Set(["hero", "spark"]))
      .find((value) => value.field === "binding");
    expect(issue).toMatchObject({ controlId: "mood", optionId: "happy", layerId: "hero", field: "binding" });
    expect(issue?.correction).toContain("Choose artwork");
  });
  it("rejects an empty binding atomically and preserves the last valid document", () => {
    const source = document();
    const snapshot = structuredClone(source);
    const operations: StickerOperationV1[] = [{
      op: "updateConfiguration",
      changes: { upsertVariants: [{ id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero" }] }] },
    }];
    expect(() => applyStickerOperationsV1(source, operations)).toThrow(/Option mood=happy has no change for layer hero/);
    expect(source).toEqual(snapshot);
    const invalid = structuredClone(source);
    invalid.configuration!.variants[0].layers[0] = { layerId: "hero" };
    const parsed = StickerDocumentSchema.safeParse(invalid);
    expect(parsed.success).toBe(false);
    if (!parsed.success) expect(parsed.error.issues[0]).toMatchObject({
      params: { controlId: "mood", optionId: "happy", layerId: "hero", field: "binding" },
    });
  });

  /**
   * The keyframe budget is the one rule that adds up across layers, so it is the one place where
   * checking each layer's states on its own is not enough: three layers that are each light until
   * their own control is turned up are heavy together in a pairing no per-layer pass ever resolves.
   */
  it("rejects motion the controls can reach together but never reach one layer at a time", () => {
    const heavy = [
      { type: "wiggle", amplitudeDegrees: 6, cycles: 7, delay: 0, duration: 1.5, easing: "linear" },
      { type: "bounce", height: 0.1, bounces: 6, delay: 0, duration: 1.5, easing: "easeInOut" },
      { type: "pulse", minScale: 0.9, maxScale: 1.1, cycles: 7, delay: 0, duration: 1.5, easing: "easeInOut" },
    ];
    const source = structuredClone(fixture) as unknown as {
      layers: Record<string, unknown>[];
      configuration: { controls: Record<string, unknown>[]; variants: Record<string, unknown>[] };
    };
    for (const id of ["understudy", "chorus", "ensemble", "extras"]) {
      source.layers.push({ ...structuredClone(fixture.layers[0]), id, name: id });
      source.configuration.controls.push({ id: `${id}Move`, label: `${id} movement`, type: "choice", defaultValue: "still",
        options: [{ id: "still", label: "Still" }, { id: "busy", label: "Busy" }] });
      source.configuration.variants.push(
        { id: `${id}_still`, selections: { [`${id}Move`]: "still" }, layers: [{ layerId: id, animations: [] }] },
        { id: `${id}_busy`, selections: { [`${id}Move`]: "busy" }, layers: [{ layerId: id, animations: heavy }] },
      );
    }
    // Every state one layer at a time is comfortably legal; it is only the sum that is not.
    for (const values of configurationCoverage(StickerConfigurationSchema.parse(source.configuration))) {
      const resolved = resolveStickerConfiguration(StickerDocumentSchema.parse({ ...source, configuration: undefined }) as never, values);
      expect(StickerDocumentSchema.safeParse(resolved).success).toBe(true);
    }
    const result = StickerDocumentSchema.safeParse(source);
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error)).toContain("its controls can reach");
  });
});

describe("configurable plans", () => {
  const plan = () => PlanV1Schema.parse({ version: 1, title: "Pet", summary: "Mood and pose", kind: "animated",
    timing: { durationSeconds: 2, fps: 24, loop: "loop" }, layers: [{ layerId: "hero", name: "Pet", x: 0.5, y: 0.5, scaleX: 1, scaleY: 1, source: { kind: "generate", prompt: "The approved pet" } }],
    configuration: { controls: fixture.configuration.controls.slice(0, 2), variants: fixture.configuration.variants.map((variant) => variant.id === "sad"
      ? { ...variant, layers: [{ layerId: "hero", source: { kind: "frames", prompt: "Sad pet", columns: 4, rows: 2, frameCount: 8, frameRate: 8, playback: "loop" } }] } : variant) },
  });
  it("counts all generated sheets, preserves untouched controls, and supports explicit removal", () => {
    const source = plan();
    expect(planGenerationCount(source)).toBe(2);
    expect(composeCreditHold(source)).toBe(jobCreditHold("compose") + jobCreditHold("image"));
    expect(applyPlanEdit(source, { title: "Renamed" }).configuration).toEqual(source.configuration);
    expect(applyPlanEdit(source, { clearConfiguration: true }).configuration).toBeUndefined();
    const a = configurationFromPlan(source, "11111111-1111-4111-8111-111111111111");
    expect(configurationFromPlan(source, "11111111-1111-4111-8111-111111111111")).toEqual(a);
    expect(a!.variants[1].layers[0].source).toMatchObject({ kind: "sequence", frameCount: 8 });
    expect(JSON.stringify(a)).not.toContain("prompt");
  });
  it("rejects empty and clipped generated sprite cells", async () => {
    const blank = await sharp({ create: { width: 128, height: 64, channels: 4, background: "#00000000" } }).png().toBuffer();
    await expect(validateGeneratedAtlas(blank, { columns: 2, rows: 1, frameCount: 2 })).rejects.toThrow("empty");
    const opaque = await sharp({ create: { width: 128, height: 64, channels: 4, background: "red" } }).png().toBuffer();
    await expect(validateGeneratedAtlas(opaque, { columns: 2, rows: 1, frameCount: 2 })).rejects.toThrow("clipped");
    const cell = await sharp({ create: { width: 32, height: 32, channels: 4, background: "red" } }).png().toBuffer();
    const aligned = await sharp(blank).composite([{ input: cell, left: 16, top: 16 }, { input: cell, left: 80, top: 16 }]).png().toBuffer();
    await expect(validateGeneratedAtlas(aligned, { columns: 2, rows: 1, frameCount: 2 })).resolves.toBeUndefined();
  });

  // The reported artifact: a plane whose wing overshot its cell and reappeared as a sliver inside
  // the neighbouring frame. The wing crosses the boundary over only 8 rows, which is under the
  // `(width + height) * 0.1` border-ring count the gate used to apply, so this sheet passed
  // validation and the bleed was baked into every pose.
  it("rejects a thin overshoot that the border-ring count let through", async () => {
    const blank = await sharp({ create: { width: 128, height: 64, channels: 4, background: "#00000000" } }).png().toBuffer();
    const body = await sharp({ create: { width: 32, height: 32, channels: 4, background: "red" } }).png().toBuffer();
    const wing = await sharp({ create: { width: 20, height: 8, channels: 4, background: "red" } }).png().toBuffer();
    const bled = await sharp(blank).composite([
      { input: body, left: 16, top: 16 },
      // Starts inside cell 0 and runs to x=67, four pixels past the 64px boundary.
      { input: wing, left: 48, top: 30 },
      { input: body, left: 80, top: 16 },
    ]).png().toBuffer();
    await expect(validateGeneratedAtlas(bled, { columns: 2, rows: 1, frameCount: 2 }))
      .rejects.toThrow("frame 1 is clipped at its cell boundary");
  });

  it("rejects artwork left in a cell the sheet never asked for", async () => {
    const blank = await sharp({ create: { width: 128, height: 64, channels: 4, background: "#00000000" } }).png().toBuffer();
    const body = await sharp({ create: { width: 32, height: 32, channels: 4, background: "red" } }).png().toBuffer();
    const extra = await sharp(blank).composite([
      { input: body, left: 16, top: 16 },
      { input: body, left: 80, top: 16 },
    ]).png().toBuffer();
    await expect(validateGeneratedAtlas(extra, { columns: 2, rows: 1, frameCount: 1 }))
      .rejects.toThrow("artwork in unused cell 2");
  });
});
