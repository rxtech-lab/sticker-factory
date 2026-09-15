/**
 * Emits `fixtures/sticker-document-v5-cast.json`, the shared contract fixture for two controllable
 * characters on one canvas, each with mood and pose controls of its own.
 *
 * It is what proves the Swift and TypeScript validators agree that a cast's states add rather than
 * multiply: thirty-six pairings, twelve prepared states, six per character. Built by doubling the
 * single-character fixture rather than by hand, so the two can never drift apart.
 *
 *   bun run scripts/emit-sprite-cast-fixture.ts
 *   cp fixtures/sticker-document-v5-cast.json ../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/
 */

import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import sprite from "@/fixtures/sticker-document-v5-sprite.json";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";

type Loose = { id?: string; name?: string; anchor?: { position: { x: number; y: number } } } & Record<string, unknown>;
const hero = structuredClone(sprite.layers[0]) as Loose;
const dog: Loose = { ...structuredClone(hero), id: "sidekick", name: "Dog" };
if (hero.anchor) hero.anchor.position = { ...hero.anchor.position, x: 0.3 };
if (dog.anchor) dog.anchor.position = { ...dog.anchor.position, x: 0.7 };

const faces = ["neutral", "happy", "sad"];
const clips = ["idle", "wave"];
const titled = (id: string) => id[0].toUpperCase() + id.slice(1);
const characterControls = (prefix: string, name: string) => [
  { id: `${prefix}Mood`, type: "choice", label: `${name} mood`, defaultValue: "neutral",
    options: faces.map((id) => ({ id, label: titled(id) })) },
  { id: `${prefix}Pose`, type: "choice", label: `${name} pose`, defaultValue: "idle",
    options: clips.map((id) => ({ id, label: titled(id) })) },
];

const characterVariants = (layerId: string, prefix: string) => [
  ...faces.map((id) => ({ id: `${prefix}_${id}`, selections: { [`${prefix}Mood`]: id }, layers: [{ layerId, expression: id }] })),
  ...clips.map((id) => ({ id: `${prefix}_${id}`, selections: { [`${prefix}Pose`]: id }, layers: [{ layerId, clip: id }] })),
];

const document = StickerDocumentSchema.parse({
  ...sprite,
  layers: [hero, dog, ...sprite.layers.slice(1)],
  configuration: {
    controls: [
      ...characterControls("cat", "Cat"),
      ...characterControls("dog", "Dog"),
      { id: "sparkles", type: "toggle", label: "Sparkles", defaultValue: true, layerIds: ["spark"] },
      { id: "speed", type: "number", label: "Speed", defaultValue: 1, minimum: 0.25, maximum: 2, step: 0.05, binding: "speed" },
    ],
    variants: [...characterVariants("hero", "cat"), ...characterVariants("sidekick", "dog")],
  },
});

const path = resolve(dirname(fileURLToPath(import.meta.url)), "../fixtures/sticker-document-v5-cast.json");
writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`);
console.log(`Wrote ${path}`);
