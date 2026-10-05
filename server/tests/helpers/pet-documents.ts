import { readFileSync } from "node:fs";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";

/**
 * A pet made of one shape that fades in over the first second, with a toggle that hides it.
 *
 * The fade is the point: at t=0 the sticker is an empty square, which is what a naive still would
 * hand the watch.
 */
export function fadingPet(): StickerDocument {
  const base = StickerDocumentSchema.parse(JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")));
  const empty = { ...base, layers: [] } as StickerDocument;
  const withLayer = applyStickerOperationsV1(empty, [
    {
      op: "addLayer",
      layer: {
        id: "body",
        name: "body",
        hidden: false,
        anchor: {
          position: { x: 0.5, y: 0.5 }, scale: { x: 0.8, y: 0.8 }, rotationDegrees: 0, opacity: 1,
          trim: { start: 0, end: 1 },
        },
        blendMode: "normal",
        type: "shape",
        shape: { kind: "circle" },
        fill: { type: "solid", color: "#FFD166" },
        cornerRadius: 0.12,
        animations: [],
        animation: {
          position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
        },
      },
    } as never,
    { op: "setLayerAnimations", layerId: "body", animations: [{ type: "fadeIn", duration: 1, easing: "linear" }] } as never,
  ]);
  return StickerDocumentSchema.parse({
    ...withLayer,
    configuration: {
      controls: [{ id: "visible", label: "Visible", type: "toggle", defaultValue: true, layerIds: ["body"] }],
      variants: [],
    },
  });
}
