import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { resolveChatAction, validatePlannedAnimationOperation } from "@/lib/ai/gateway";
import { CreateUploadRequestSchema, PostChatMessageRequestSchema } from "@/lib/contracts/api";
import { StickerDocumentV1Schema } from "@/lib/contracts/sticker";
import { validateAnimatedRenditionTiming } from "@/lib/services/stickers";
import { inspectImage } from "@/lib/storage/r2";
import { assertTargetedAnimationOperation } from "@/workflows/sticker-generation/steps";

describe("media and animation hardening", () => {
  it("uses per-frame canvas height and verified timing for animated images", async () => {
    const gif = await sharp({
      create: { width: 64, height: 128, pageHeight: 64, channels: 4, background: { r: 20, g: 40, b: 60, alpha: 0.5 } },
    }).gif({ delay: [30, 40], keepDuplicateFrames: true }).toBuffer();
    const inspected = await inspectImage(gif);
    expect(inspected).toMatchObject({ width: 64, height: 64, frameCount: 2, durationSeconds: 0.07 });
  });

  it("permits safe non-image layer planning but blocks invented image assets", () => {
    const shape = {
      op: "addLayer" as const,
      layer: {
        id: "spark",
        name: "Spark",
        hidden: false,
        type: "shape" as const,
        shape: "star" as const,
        fill: "#FFFFFF",
        strokeWidth: 0,
        cornerRadius: 0.12,
        anchor: { position: { x: 0.5, y: 0.5 }, scale: { x: 1, y: 1 }, rotationDegrees: 0, opacity: 1 },
        animations: [],
        animation: { position: [], scale: [], rotation: [], opacity: [], effects: [] },
      },
    };
    expect(validatePlannedAnimationOperation(shape)).toBe(shape);
    expect(() => validatePlannedAnimationOperation({
      op: "addLayer",
      layer: { ...shape.layer, type: "image", assetId: crypto.randomUUID(), contentMode: "fit" },
    } as never)).toThrow(/ownership/);
  });

  it("prevents structural operations from escaping a targeted animation", () => {
    expect(() => assertTargetedAnimationOperation({ op: "setScaleKeyframes", layerId: "hero", keyframes: [] }, "hero")).not.toThrow();
    expect(() => assertTargetedAnimationOperation({ op: "setScaleKeyframes", layerId: "other", keyframes: [] }, "hero")).toThrow(/outside/);
    // The operation the planner is told to prefer: a targeted animation is nothing but this.
    expect(() => assertTargetedAnimationOperation({
      op: "setLayerAnimations",
      layerId: "hero",
      animations: [{ type: "pulse", delay: 0, duration: 0.6, easing: "easeInOut", minScale: 0.92, maxScale: 1.08, cycles: 3 }],
    }, "hero")).not.toThrow();
    expect(() => assertTargetedAnimationOperation({
      op: "setLayerAnimations",
      layerId: "other",
      animations: [],
    }, "hero")).toThrow(/outside/);
    expect(() => assertTargetedAnimationOperation({
      op: "addLayer",
      layer: {
        id: "spark", name: "Spark", hidden: false, type: "particle", preset: "sparkles", count: 4, color: "#FFFFFF", seed: 7,
        anchor: { position: { x: 0.5, y: 0.5 }, scale: { x: 1, y: 1 }, rotationDegrees: 0, opacity: 1 },
        animations: [],
        animation: { position: [], scale: [], rotation: [], opacity: [], effects: [] },
      },
    }, "hero")).toThrow(/outside/);
  });

  it("requires an accepted-base identifier for animation and rejects GIF references at intent time", () => {
    expect(() => PostChatMessageRequestSchema.parse({ text: "Bounce", intent: "animate", attachments: [], imagePlacement: "replace" })).toThrow(/accepted active base/);
    expect(() => CreateUploadRequestSchema.parse({ kind: "reference", mimeType: "image/gif", byteSize: 100, filename: "bomb.gif" })).toThrow(/PNG, JPEG, or WebP/);
  });

  it("accepts a one-frame adaptive system duration tolerance and enforces its FPS floor", () => {
    const document = StickerDocumentV1Schema.parse({
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      kind: "animated",
      durationSeconds: 0.51,
      fps: 30,
      loop: "loop",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers: [],
    });
    if (document.kind !== "animated") throw new Error("Animated timing fixture did not parse as animated");
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 5, durationSeconds: 0.625, fps: 8 })).not.toThrow();
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 4, durationSeconds: 4 / 7, fps: 7 }))
      .toThrow(/FPS/);
  });

  it("reconciles a routed edit with the layers the image tools can actually touch", () => {
    const documentWith = (...layers: unknown[]) => StickerDocumentV1Schema.parse({
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers,
    });
    const text = { id: "omg_text", name: "OMG", type: "text", text: "OMG", font: "rounded", weight: "bold", color: "#FF0055" };
    const hero = { id: "hero", name: "Hero", type: "image", assetId: crypto.randomUUID(), contentMode: "fit" };
    const edit = { type: "edit" as const, instruction: "Make the OMG cartoon-like", imagePlacement: "replace" as const };

    // The bug this guards: the router sees `omg_text` in the document and targets it, and the
    // workflow then fails the turn on a layer the image model was never able to redraw.
    expect(resolveChatAction({ ...edit, targetLayerId: "omg_text" }, documentWith(text, hero)))
      .toEqual({ type: "plan", instruction: edit.instruction });
    // An id that names nothing is dropped rather than obeyed, so the edit finds the image itself.
    expect(resolveChatAction({ ...edit, targetLayerId: "invented" }, documentWith(hero)))
      .toEqual({ ...edit, targetLayerId: undefined });
    expect(resolveChatAction({ ...edit, targetLayerId: "hero" }, documentWith(text, hero)))
      .toEqual({ ...edit, targetLayerId: "hero" });
    // Nothing drawn to edit: adding one element is a generation, changing the rest needs a plan.
    expect(resolveChatAction({ ...edit, imagePlacement: "add" }, documentWith(text)))
      .toEqual({ type: "generate_image", instruction: edit.instruction });
    expect(resolveChatAction(edit, documentWith(text))).toEqual({ type: "plan", instruction: edit.instruction });
    expect(resolveChatAction(edit, undefined)).toEqual({ type: "generate", instruction: edit.instruction });
    // Animation keyframes any layer type, so only an id naming nothing at all is unusable.
    const animate = { type: "animate" as const, instruction: "Pulse it" };
    expect(resolveChatAction({ ...animate, targetLayerId: "omg_text" }, documentWith(text)))
      .toEqual({ ...animate, targetLayerId: "omg_text" });
    expect(resolveChatAction({ ...animate, targetLayerId: "invented" }, documentWith(text)))
      .toEqual({ ...animate, targetLayerId: undefined });
  });
});
