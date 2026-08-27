import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { resolveChatAction, validateEditOperation, validatePlannedAnimationOperation } from "@/lib/ai/gateway";
import { CreateUploadRequestSchema, PostChatMessageRequestSchema } from "@/lib/contracts/api";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
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
        shape: { kind: "star" as const, points: 5, innerRatio: 0.42 },
        fill: { type: "solid" as const, color: "#FFFFFF" },
        cornerRadius: 0.12,
        blendMode: "normal" as const,
        anchor: { position: { x: 0.5, y: 0.5 }, scale: { x: 1, y: 1 }, rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 } },
        animations: [],
        animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [] },
      },
    };
    expect(validatePlannedAnimationOperation(shape)).toBe(shape);
    expect(() => validatePlannedAnimationOperation({
      op: "addLayer",
      layer: { ...shape.layer, type: "image", assetId: crypto.randomUUID(), contentMode: "fit" },
    } as never)).toThrow(/ownership/);

    // The edit loop's free tool draws the same line: it may restructure the stack however it likes,
    // but artwork has to come from a redraw that was generated, stored, and paid for.
    expect(validateEditOperation(shape)).toBe(shape);
    expect(validateEditOperation({ op: "removeLayer", layerId: "omg_text" }))
      .toEqual({ op: "removeLayer", layerId: "omg_text" });
    expect(() => validateEditOperation({
      op: "addLayer",
      layer: { ...shape.layer, type: "image", assetId: crypto.randomUUID(), contentMode: "fit" },
    } as never)).toThrow(/add_image_layer/);
    expect(() => validateEditOperation({
      op: "replaceAsset", layerId: "hero", assetId: crypto.randomUUID(),
    })).toThrow(/edit_image_layer/);
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
        id: "spark", name: "Spark", hidden: false, type: "particle", preset: "sparkles", count: 4,
        paint: { type: "solid", color: "#FFFFFF" }, seed: 7, blendMode: "normal",
        anchor: { position: { x: 0.5, y: 0.5 }, scale: { x: 1, y: 1 }, rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 } },
        animations: [],
        animation: { position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [] },
      },
    }, "hero")).toThrow(/outside/);
  });

  it("requires an explicit base identifier for animation and rejects GIF references at intent time", () => {
    expect(() => PostChatMessageRequestSchema.parse({ text: "Bounce", intent: "animate", attachments: [], imagePlacement: "replace" })).toThrow(/explicit base revision/);
    expect(() => CreateUploadRequestSchema.parse({ kind: "reference", mimeType: "image/gif", byteSize: 100, filename: "bomb.gif" })).toThrow(/PNG, JPEG, or WebP/);
  });

  it("accepts a one-frame adaptive system duration tolerance and enforces its FPS floor", () => {
    const document = StickerDocumentSchema.parse({
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
    // A 0.51 s cycle plus the 0.6 s loop hold: 1.11 s of wall clock over a 5-frame motion grid.
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 5, durationSeconds: 1.11, fps: 5 / 1.11 })).not.toThrow();
    // One frame of encoder slack on top of that is still accepted.
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 5, durationSeconds: 1.21, fps: 5 / 1.21 })).not.toThrow();
    // The grid is recovered from the cycle, not the held duration, so the floor still bites: three
    // frames over 0.51 s is 5.9 fps, under the ladder's 8 fps floor.
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 3, durationSeconds: 1.11, fps: 3 / 1.11 }))
      .toThrow(/FPS/);
    // A rendition encoded without the hold is the regression this guards: right frames, short file.
    expect(() => validateAnimatedRenditionTiming(document, { kind: "system", frameCount: 5, durationSeconds: 0.51, fps: 5 / 0.51 }))
      .toThrow(/duration/);
  });

  it("measures an export against wall clock, not the authored duration", () => {
    // `speed` divides elapsed time on the way into the interpolator rather than rewriting
    // keyframes, so a 2s document at 2x is a 1s cycle on screen and in every export. Comparing the
    // rendition against the authored 2s instead would reject every correctly rendered export of a
    // document not playing at 1x.
    const atSpeed = (speed: number) => {
      const document = StickerDocumentSchema.parse({
        version: 2,
        canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
        kind: "animated",
        durationSeconds: 2,
        fps: 30,
        loop: "loop",
        speed,
        mp4Background: { type: "solid", color: "#FFFFFF" },
        layers: [],
      });
      if (document.kind !== "animated") throw new Error("timing fixture did not parse as animated");
      return document;
    };

    const hold = 0.6;
    // 1x: a 2s cycle, 60 frames at 30fps.
    expect(() => validateAnimatedRenditionTiming(
      atSpeed(1), { kind: "gif", frameCount: 60, durationSeconds: 2 + hold, fps: 30 },
    )).not.toThrow();
    // 2x: the same document is a 1s cycle, 30 frames.
    expect(() => validateAnimatedRenditionTiming(
      atSpeed(2), { kind: "gif", frameCount: 30, durationSeconds: 1 + hold, fps: 30 },
    )).not.toThrow();
    // The regression: a 2x document rendered as if it were still 2s long.
    expect(() => validateAnimatedRenditionTiming(
      atSpeed(2), { kind: "gif", frameCount: 60, durationSeconds: 2 + hold, fps: 30 },
    )).toThrow();
  });

  it("reconciles a routed edit with the layers the document actually has", () => {
    const documentWith = (...layers: unknown[]) => StickerDocumentSchema.parse({
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

    // The edit tool owns the whole layer stack, so an app-drawn layer is a legitimate target and is
    // left alone rather than rewritten into a plan the user then has to confirm.
    expect(resolveChatAction({ ...edit, targetLayerId: "omg_text" }, documentWith(text, hero)))
      .toEqual({ ...edit, targetLayerId: "omg_text" });
    // An id that names nothing is dropped rather than obeyed, so the edit picks its own target.
    expect(resolveChatAction({ ...edit, targetLayerId: "invented" }, documentWith(hero)))
      .toEqual({ ...edit, targetLayerId: undefined });
    expect(resolveChatAction({ ...edit, targetLayerId: "hero" }, documentWith(text, hero)))
      .toEqual({ ...edit, targetLayerId: "hero" });
    // A sticker with no drawn artwork in it is still editable: its text layer can be removed,
    // reworded, moved, or replaced with artwork, all of which is an edit.
    expect(resolveChatAction({ ...edit, imagePlacement: "add" }, documentWith(text)))
      .toEqual({ ...edit, imagePlacement: "add" });
    expect(resolveChatAction(edit, documentWith(text))).toEqual(edit);
    // Nothing to edit at all, though, is a first generation.
    expect(resolveChatAction(edit, undefined)).toEqual({ type: "generate", instruction: edit.instruction });
    // Animation keyframes any layer type, so only an id naming nothing at all is unusable.
    const animate = { type: "animate" as const, instruction: "Pulse it" };
    expect(resolveChatAction({ ...animate, targetLayerId: "omg_text" }, documentWith(text)))
      .toEqual({ ...animate, targetLayerId: "omg_text" });
    expect(resolveChatAction({ ...animate, targetLayerId: "invented" }, documentWith(text)))
      .toEqual({ ...animate, targetLayerId: undefined });
  });
});
