import { describe, expect, it } from "vitest";
import fixture from "@/fixtures/sticker-document-v5-sprite.json";
import { composeCreditHold, jobCreditHold } from "@/lib/subscription/pricing";
import { PlanV1Schema, assertControllablePlan, assertPlanAllowedForJob, planGenerationCount, planSpriteSheetCount } from "@/lib/contracts/plan";
import { CreateStickerRequestSchema } from "@/lib/contracts/api";
import { configurationCoverage, configurationLayerCombinations, configurationSelections } from "@/lib/contracts/configuration";
import {
  StickerDocumentSchema, documentRenderableLayers, downcastForClient, layerImageAssetIds, resolveStickerConfiguration, spriteClip, spriteExpressionTile,
} from "@/lib/contracts/sticker";

const document = () => StickerDocumentSchema.parse(fixture);

describe("sprite layer contract", () => {
  it("round trips the shared Swift fixture byte for byte", () => {
    const source = document();
    expect(JSON.parse(JSON.stringify(source))).toEqual(fixture);
    expect(configurationSelections(source.configuration!)).toHaveLength(6);
    expect(configurationCoverage(source.configuration!)).toHaveLength(6);
    expect(configurationLayerCombinations(source.configuration!)).toEqual(new Map([["hero", 6]]));
  });

  /** A second character on the same canvas, with controls of its own and no axis shared with the first. */
  type Loose = { layers: Record<string, unknown>[]; configuration: { controls: Record<string, unknown>[]; variants: Record<string, unknown>[] } };
  const duet = () => {
    const source = structuredClone(fixture) as unknown as Loose;
    const sidekick = structuredClone(fixture.layers[0]) as Record<string, unknown>;
    Object.assign(sidekick, { id: "sidekick", name: "Dog" });
    source.layers.push(sidekick);
    source.configuration.controls.push(
      { id: "dogMood", label: "Dog mood", type: "choice", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }, { id: "sad", label: "Sad" }] },
      { id: "dogPose", label: "Dog pose", type: "choice", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "wave", label: "Wave" }] },
    );
    source.configuration.variants.push(
      ...["neutral", "happy", "sad"].map((id) => ({ id: `dog_${id}`, selections: { dogMood: id }, layers: [{ layerId: "sidekick", expression: id }] })),
      ...["idle", "wave"].map((id) => ({ id: `dog_${id}`, selections: { dogPose: id }, layers: [{ layerId: "sidekick", clip: id }] })),
    );
    return source;
  };

  // Two characters at six states each are twelve states to prepare, not thirty-six: one character's
  // pose cannot change how the other resolves, so their options never multiply together.
  it("prepares two characters per layer rather than across the cast", () => {
    const source = duet();
    const parsed = StickerDocumentSchema.parse(source);
    expect(configurationLayerCombinations(parsed.configuration!)).toEqual(new Map([["hero", 6], ["sidekick", 6]]));
    expect(configurationCoverage(parsed.configuration!)).toHaveLength(12);
    expect(configurationSelections(parsed.configuration!)).toHaveLength(36);

    const result = resolveStickerConfiguration(parsed, { mood: "sad", pose: "wave", dogMood: "happy", dogPose: "idle" });
    const [hero, , dog] = result.layers;
    if (hero.type !== "sprite" || dog.type !== "sprite") throw new Error("both characters should stay sprites");
    expect([hero.clipId, hero.expressionId]).toEqual(["wave", "sad"]);
    expect([dog.clipId, dog.expressionId]).toEqual(["idle", "happy"]);
  });

  // Two controls on one sprite can only ever reach 8 * 8, so the overflow has to be built the way
  // the editor's combined tables are: two axes selected together in one variant, twice over.
  it("caps combinations per character and names the one that overflows", () => {
    const source = duet();
    const faces = ["neutral", "happy", "sad"];
    source.configuration.controls = source.configuration.controls.filter((control) => !String(control.id).startsWith("dog"));
    source.configuration.variants = source.configuration.variants.filter((variant) => !String(variant.id).startsWith("dog_"));
    for (const [first, second, property, values] of [["hat", "scarf", "expression", faces], ["gait", "tilt", "clip", ["idle", "wave", "idle"]]] as const) {
      for (const axis of [first, second]) {
        source.configuration.controls.push({ id: axis, label: axis, type: "choice", defaultValue: "a",
          options: ["a", "b", "c"].map((id) => ({ id, label: id.toUpperCase() })) });
      }
      ["a", "b", "c"].forEach((left, leftIndex) => ["a", "b", "c"].forEach((right) => {
        source.configuration.variants.push({ id: `${first}_${left}_${right}`, selections: { [first]: left, [second]: right },
          layers: [{ layerId: "sidekick", [property]: values[leftIndex] }] });
      }));
    }
    // Three options on each of four axes, all acting on the dog: 81 states for one character.
    expect(StickerDocumentSchema.safeParse({ ...source, configuration: undefined }).success).toBe(true);
    const result = StickerDocumentSchema.safeParse(source);
    expect(result.success).toBe(false);
    expect(JSON.stringify(result.error)).toContain("Character sidekick has 81 mood/pose combinations");
  });

  it("selects a clip and an expression independently, leaving the sheets untouched", () => {
    const source = document();
    const result = resolveStickerConfiguration(source, { mood: "sad", pose: "wave", sparkles: false, speed: 0.5 });
    const hero = result.layers[0];
    if (hero.type !== "sprite") throw new Error("hero should stay a sprite");
    expect(hero.clipId).toBe("wave");
    expect(hero.expressionId).toBe("sad");
    expect(spriteClip(hero).assetId).toBe("32222222-2222-4222-8222-222222222222");
    expect(spriteExpressionTile(hero).x).toBe(0.71);
    expect(hero.clips).toEqual(fixture.layers[0].clips);
    expect(result.layers[1].hidden).toBe(true);
    expect(result.speed).toBe(0.5);
    // Only the mood changed: the pose stays on the authored default.
    const moodOnly = resolveStickerConfiguration(source, { mood: "happy" });
    expect(moodOnly.layers[0]).toMatchObject({ clipId: "idle", expressionId: "happy" });
    expect(source.layers[0]).toMatchObject({ clipId: "idle", expressionId: "neutral" });
  });

  it("lists every sheet as artwork the document needs, and only the poster for older clients", () => {
    const source = document();
    expect(layerImageAssetIds(source.layers[0])).toEqual([
      "31111111-1111-4111-8111-111111111111", "32222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333",
    ]);
    // Six selections resolve to six distinct sprite states, but the artwork set never grows.
    const renderable = documentRenderableLayers(source).filter((layer) => layer.type === "sprite");
    expect(renderable.length).toBe(6);
    expect(new Set(renderable.flatMap(layerImageAssetIds)).size).toBe(3);
    const legacy = downcastForClient(source, 4);
    expect(legacy).toMatchObject({ version: 4, layers: [{ type: "image", assetId: "34444444-4444-4444-8444-444444444444", name: "Cat" }, {}] });
    expect(legacy).not.toHaveProperty("configuration");
    expect(StickerDocumentSchema.parse(legacy).version).toBe(5);
  });

  it.each(["static", "clip", "expression", "default", "source", "fps", "layer"])("rejects an invalid %s before rendering", (failure) => {
    const source = structuredClone(fixture) as Record<string, unknown> & typeof fixture;
    if (failure === "static") Object.assign(source, { kind: "static", durationSeconds: 0, fps: 0, loop: "once", configuration: undefined });
    if (failure === "clip") source.configuration.variants[4].layers[0] = { layerId: "hero", clip: "dance" } as never;
    if (failure === "expression") source.configuration.variants[1].layers[0] = { layerId: "hero", expression: "angry" } as never;
    if (failure === "default") source.layers[0].clipId = "dance";
    if (failure === "source") source.configuration.variants[1].layers[0] = { layerId: "hero", source: { kind: "base" } } as never;
    if (failure === "fps") source.fps = 4;
    if (failure === "layer") source.configuration.variants[3].layers[0] = { layerId: "spark", clip: "idle" } as never;
    expect(StickerDocumentSchema.safeParse(source).success).toBe(false);
  });

  it("keeps mood and pose from claiming each other's property", () => {
    const source = structuredClone(fixture);
    // Two families binding `hero.clip` is a conflict, exactly as two families binding a source is.
    source.configuration.variants[1].layers[0] = { layerId: "hero", clip: "wave" } as never;
    expect(StickerDocumentSchema.safeParse(source).success).toBe(false);
  });
});

describe("sprite plans", () => {
  const plan = (overrides: Record<string, unknown> = {}) => PlanV1Schema.parse({
    version: 1, title: "Cat", summary: "A cat with moods and poses", kind: "animated",
    timing: { durationSeconds: 3, fps: 24, loop: "loop" },
    layers: [{ layerId: "hero", name: "Cat", x: 0.5, y: 0.5, scaleX: 1, scaleY: 1, source: {
      kind: "sprite", prompt: "A round orange cat",
      clips: [
        { id: "idle", label: "Idle", prompt: "breathes and blinks", frames: [{ duration: 2.4 }, { duration: 0.18 }, { duration: 0.28 }, { duration: 0.22 }, { duration: 0.3 }, { duration: 1.2 }] },
        { id: "wave", label: "Wave", prompt: "raises a paw and waves", frames: [{ duration: 0.4 }, { duration: 0.3 }, { duration: 0.35 }, { duration: 0.3 }, { duration: 0.35 }, { duration: 0.7 }] },
      ],
      expressions: [{ id: "neutral", label: "Neutral", prompt: "calm eyes" }, { id: "happy", label: "Happy", prompt: "closed smiling eyes" }],
    } }],
    configuration: { controls: [
      { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }] },
      { id: "pose", type: "choice", label: "Pose", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "wave", label: "Wave" }] },
    ], variants: [
      { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
      { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
      { id: "idle", selections: { pose: "idle" }, layers: [{ layerId: "hero", clip: "idle" }] },
      { id: "wave", selections: { pose: "wave" }, layers: [{ layerId: "hero", clip: "wave" }] },
    ] },
    ...overrides,
  });

  it("costs one still, one sheet per clip, and one expression sheet", () => {
    const source = plan();
    expect(planSpriteSheetCount(source)).toBe(3);
    expect(planGenerationCount(source)).toBe(4);
    expect(composeCreditHold(source)).toBe(jobCreditHold("compose") + 3 * 2 * jobCreditHold("image"));
    expect(() => assertPlanAllowedForJob(source, { quick: true })).toThrow(/quick mode/);
    expect(() => assertPlanAllowedForJob(source, { quick: false })).not.toThrow();
  });

  it("rejects bindings the sprite does not declare, artwork swaps on a sprite, and static plans", () => {
    const base = plan();
    const withVariant = (index: number, patch: Record<string, unknown>) => {
      const next = structuredClone(base);
      next.configuration!.variants[index].layers[0] = { layerId: "hero", ...patch } as never;
      return PlanV1Schema.safeParse(next).success;
    };
    expect(withVariant(3, { clip: "dance" })).toBe(false);
    expect(withVariant(1, { expression: "angry" })).toBe(false);
    expect(withVariant(1, { source: { kind: "generate", prompt: "happy cat" } })).toBe(false);
    const still = structuredClone(base);
    Object.assign(still, { kind: "static", configuration: undefined });
    expect(PlanV1Schema.safeParse(still).success).toBe(false);
    const repeated = structuredClone(base);
    if (repeated.layers[0].source.kind === "sprite") repeated.layers[0].source.clips[1].id = "idle";
    expect(PlanV1Schema.safeParse(repeated).success).toBe(false);
  });

  // The switch in the create screen, not a sentence the user typed. The planner is told about it in
  // its prompt; this is what makes it a requirement rather than a suggestion.
  it("holds a controllable project to a sprite that a control actually selects", () => {
    expect(() => assertControllablePlan(plan())).not.toThrow();

    const drawn = structuredClone(plan());
    drawn.layers[0].source = { kind: "generate", prompt: "A round orange cat, happy" } as never;
    drawn.configuration = undefined;
    expect(() => assertControllablePlan(drawn)).toThrow(/sprite source/);

    // A sprite nothing selects between is just an animation with one clip: no picker reaches the
    // controls sheet, so the user ends up exactly where the toggle was meant to take them off.
    const unbound = structuredClone(plan());
    unbound.configuration = undefined;
    expect(() => assertControllablePlan(unbound)).toThrow(/no controls/);
  });

  /** A cast: one sprite layer each, one pair of controls each, no shared axis between them. */
  const duet = () => {
    const source = structuredClone(plan());
    const dog = structuredClone(source.layers[0]);
    Object.assign(dog, { layerId: "sidekick", name: "Dog", x: 0.75 });
    if (dog.source.kind === "sprite") dog.source.prompt = "A small grey dog";
    source.layers.push(dog);
    source.configuration!.controls.push(
      { id: "dogMood", type: "choice", label: "Dog mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }] },
      { id: "dogPose", type: "choice", label: "Dog pose", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "wave", label: "Wave" }] },
    );
    source.configuration!.variants.push(
      { id: "dog_neutral", selections: { dogMood: "neutral" }, layers: [{ layerId: "sidekick", expression: "neutral" }] },
      { id: "dog_happy", selections: { dogMood: "happy" }, layers: [{ layerId: "sidekick", expression: "happy" }] },
      { id: "dog_idle", selections: { dogPose: "idle" }, layers: [{ layerId: "sidekick", clip: "idle" }] },
      { id: "dog_wave", selections: { dogPose: "wave" }, layers: [{ layerId: "sidekick", clip: "wave" }] },
    );
    return PlanV1Schema.parse(source);
  };

  it("plans two characters, each with its own controls, and charges for both", () => {
    const source = duet();
    expect(() => assertControllablePlan(source)).not.toThrow();
    expect(planSpriteSheetCount(source)).toBe(6);
    expect(planGenerationCount(source)).toBe(8);
    expect(composeCreditHold(source)).toBe(jobCreditHold("compose") + 6 * 2 * jobCreditHold("image"));
  });

  // The half-built outcome a two-character plan drifts into: a second character on screen that no
  // picker reaches. The message has to name the one that is actually unbound, not the first sprite.
  it("names the character a control forgot", () => {
    const source = structuredClone(duet());
    source.configuration!.controls = source.configuration!.controls.slice(0, 2);
    source.configuration!.variants = source.configuration!.variants.slice(0, 4);
    expect(() => assertControllablePlan(source)).toThrow(/Sprite sidekick has no controls/);
  });

  it("refuses a controllable request that no sprite could be built for", () => {
    const request = { title: "Cat", kind: "animated", prompt: "A round orange cat", referenceAssetIds: [] };
    expect(CreateStickerRequestSchema.parse({ ...request, controllable: true }).controllable).toBe(true);
    // Left out entirely by every client that predates the switch, and by the app clip.
    expect(CreateStickerRequestSchema.parse(request).controllable).toBeUndefined();
    expect(CreateStickerRequestSchema.safeParse({ ...request, kind: "static", controllable: true }).success).toBe(false);
    expect(CreateStickerRequestSchema.safeParse({ ...request, quick: true, controllable: true }).success).toBe(false);
  });
});
