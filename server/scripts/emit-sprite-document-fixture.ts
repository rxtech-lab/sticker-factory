/**
 * Emits `fixtures/sticker-document-v5-sprite.json`, the shared contract fixture for a sprite
 * character with independent mood and pose controls.
 *
 * Written through `StickerDocumentSchema` so every defaulted field is spelled out, which is what
 * lets the Swift round-trip test compare bytes. Copy it to the AnimatedView test bundle after
 * regenerating:
 *
 *   bun run scripts/emit-sprite-document-fixture.ts
 *   cp fixtures/sticker-document-v5-sprite.json ../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/
 */

import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

const IDLE = "31111111-1111-4111-8111-111111111111";
const WAVE = "32222222-2222-4222-8222-222222222222";
const FACES = "33333333-3333-4333-8333-333333333333";
const POSTER = "34444444-4444-4444-8444-444444444444";

const slot = (duration: number, faceX: number, faceY: number) => ({ duration, faceX, faceY, faceSize: 0.42 });

const document = StickerDocumentSchema.parse({
  version: 5,
  canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
  layers: [
    {
      id: "hero", name: "Cat", type: "sprite",
      anchor: { position: { x: 0.5, y: 0.5 }, scale: { x: 1, y: 1 }, rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 } },
      clips: [
        { id: "idle", assetId: IDLE, columns: 3, rows: 2, frames: [
          slot(2.4, 0.5, 0.36), slot(0.18, 0.5, 0.37), slot(0.28, 0.5, 0.37), slot(0.22, 0.5, 0.37), slot(0.3, 0.5, 0.365), slot(1.2, 0.5, 0.36),
        ] },
        { id: "wave", assetId: WAVE, columns: 3, rows: 2, frames: [
          slot(0.4, 0.5, 0.36), slot(0.3, 0.52, 0.35), slot(0.35, 0.54, 0.34), slot(0.3, 0.52, 0.35), slot(0.35, 0.5, 0.36), slot(0.7, 0.5, 0.36),
        ] },
      ],
      expressions: { assetId: FACES, columns: 3, rows: 3, tiles: [
        { id: "neutral", x: 0.05, y: 0.05, width: 0.24, height: 0.2 },
        { id: "happy", x: 0.38, y: 0.05, width: 0.24, height: 0.2 },
        { id: "sad", x: 0.71, y: 0.05, width: 0.24, height: 0.2 },
      ] },
      clipId: "idle", expressionId: "neutral", contentMode: "fit", posterAssetId: POSTER,
    },
    {
      id: "spark", name: "Spark", type: "particle", preset: "sparkles", count: 14, paint: { type: "solid", color: "#FFD166" }, seed: 11,
      anchor: { position: { x: 0.72, y: 0.28 }, scale: { x: 0.34, y: 0.34 }, rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 } },
    },
  ],
  background: { type: "none" },
  mp4Background: { type: "linearGradient", colors: ["#FFE7A3", "#FF8FA3"], angleDegrees: 35 },
  kind: "animated", durationSeconds: 4.58, fps: 24, loop: "loop", speed: 1,
  configuration: {
    controls: [
      { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [
        { id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }, { id: "sad", label: "Sad" },
      ] },
      { id: "pose", type: "choice", label: "Pose", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "wave", label: "Wave" }] },
      { id: "sparkles", type: "toggle", label: "Sparkles", defaultValue: true, layerIds: ["spark"] },
      { id: "speed", type: "number", label: "Speed", defaultValue: 1, minimum: 0.25, maximum: 2, step: 0.05, binding: "speed" },
    ],
    variants: [
      { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
      { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
      { id: "sad", selections: { mood: "sad" }, layers: [{ layerId: "hero", expression: "sad" }] },
      { id: "idle", selections: { pose: "idle" }, layers: [{ layerId: "hero", clip: "idle" }] },
      { id: "wave", selections: { pose: "wave" }, layers: [{ layerId: "hero", clip: "wave" }] },
    ],
  },
});

const path = resolve(dirname(fileURLToPath(import.meta.url)), "../fixtures/sticker-document-v5-sprite.json");
writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
console.log(`Wrote ${path}`);
