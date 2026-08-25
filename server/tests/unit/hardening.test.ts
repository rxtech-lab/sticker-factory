import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { validatePlannedAnimationOperation } from "@/lib/ai/gateway";
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
});
