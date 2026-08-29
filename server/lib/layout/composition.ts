import { z } from "zod";
import {
  applyStickerOperationsV1,
  aspectLockedScale,
  layerScaleIsAspectLocked,
  LayerIdSchema,
  StickerDocumentSchema,
  type StickerDocument,
} from "@/lib/contracts/sticker";

/**
 * One layer placement the composition reviewer may change.
 *
 * This is deliberately not a raw StickerOperation: layout review must not be able to replace an
 * asset, delete a layer, or accidentally rewrite its motion while moving it. The workflow turns a
 * placement into `setLayerAnimations` with the layer's existing animations and resting opacity /
 * trim carried over byte-for-byte.
 */
export const LayoutPlacementSchema = z.object({
  layerId: LayerIdSchema,
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  scaleX: z.number().min(0.05).max(1),
  scaleY: z.number().min(0.05).max(1),
  rotationDegrees: z.number().min(-180).max(180),
}).strict();

export const LayoutAdjustmentSchema = z.object({
  placements: z.array(LayoutPlacementSchema).max(8).optional(),
  /** Complete back-to-front layer order. A full permutation avoids ambiguous partial reorders. */
  order: z.array(LayerIdSchema).max(8).optional(),
}).strict().superRefine((value, context) => {
  if (!value.placements?.length && !value.order?.length) {
    context.addIssue({ code: "custom", message: "Provide at least one placement or a layer order" });
  }
  const placementIds = value.placements?.map((placement) => placement.layerId) ?? [];
  if (new Set(placementIds).size !== placementIds.length) {
    context.addIssue({ code: "custom", message: "Each layer may be placed only once per adjustment" });
  }
});

export type LayoutAdjustment = z.infer<typeof LayoutAdjustmentSchema>;

type Bounds = {
  left: number;
  right: number;
  top: number;
  bottom: number;
};

const LAYER_FIT = 0.86;

/** Conservative rotated bounds for the same square layer box the native/server renderers use. */
function layerBounds(layer: StickerDocument["layers"][number]): Bounds {
  const radians = (layer.anchor.rotationDegrees * Math.PI) / 180;
  const cosine = Math.abs(Math.cos(radians));
  const sine = Math.abs(Math.sin(radians));
  const halfWidth = (LAYER_FIT / 2)
    * (cosine * layer.anchor.scale.x + sine * layer.anchor.scale.y);
  const halfHeight = (LAYER_FIT / 2)
    * (sine * layer.anchor.scale.x + cosine * layer.anchor.scale.y);
  return {
    left: layer.anchor.position.x - halfWidth,
    right: layer.anchor.position.x + halfWidth,
    top: layer.anchor.position.y - halfHeight,
    bottom: layer.anchor.position.y + halfHeight,
  };
}

export type LayoutDiagnostics = {
  offCanvasLayerIds: string[];
  substantialOverlaps: Array<{
    layerIds: [string, string];
    /** Intersection area divided by the smaller layer box's area. */
    smallerLayerCoverage: number;
  }>;
};

/**
 * Deterministic geometry signals for the visual reviewer.
 *
 * Overlap is reported rather than rejected because a hat on a character or a sparkle on a word is
 * intentional. The vision pass can see that distinction; code cannot. Off-canvas placement is an
 * invariant and is rejected when an adjustment is applied.
 */
export function layoutDiagnostics(document: StickerDocument): LayoutDiagnostics {
  const visible = document.layers.filter((layer) => !layer.hidden && layer.anchor.opacity > 0);
  const bounds = new Map(visible.map((layer) => [layer.id, layerBounds(layer)]));
  const offCanvasLayerIds = visible.flatMap((layer) => {
    const box = bounds.get(layer.id)!;
    return box.left < 0 || box.right > 1 || box.top < 0 || box.bottom > 1 ? [layer.id] : [];
  });
  const substantialOverlaps: LayoutDiagnostics["substantialOverlaps"] = [];
  for (let first = 0; first < visible.length; first += 1) {
    for (let second = first + 1; second < visible.length; second += 1) {
      const a = bounds.get(visible[first].id)!;
      const b = bounds.get(visible[second].id)!;
      const width = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
      const height = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
      if (width === 0 || height === 0) continue;
      const areaA = (a.right - a.left) * (a.bottom - a.top);
      const areaB = (b.right - b.left) * (b.bottom - b.top);
      const coverage = (width * height) / Math.min(areaA, areaB);
      // Lower intersections are ordinary close composition. Covering most of the smaller layer is
      // the useful warning: it often means one independently generated element became hidden.
      if (coverage >= 0.65) {
        substantialOverlaps.push({
          layerIds: [visible[first].id, visible[second].id],
          smallerLayerCoverage: Number(coverage.toFixed(2)),
        });
      }
    }
  }
  return { offCanvasLayerIds, substantialOverlaps };
}

/** Applies a layout-only correction while preserving every layer and every generated asset. */
export function applyLayoutAdjustment(
  source: StickerDocument,
  adjustment: LayoutAdjustment,
): StickerDocument {
  const value = LayoutAdjustmentSchema.parse(adjustment);
  let document = source;

  for (const placement of value.placements ?? []) {
    const layer = document.layers.find((candidate) => candidate.id === placement.layerId);
    if (!layer) throw new Error(`Unknown layer ${placement.layerId}`);
    // Same squaring-off the plan builder applies, for the same reason and at the same moment: a
    // reviewer looking at a stretched caption reaches for a wider box, and honouring that literally
    // would stretch it further. Fitting the artwork inside the requested box is what it meant.
    const requested = { x: placement.scaleX, y: placement.scaleY };
    document = applyStickerOperationsV1(document, [{
      op: "setLayerAnimations",
      layerId: layer.id,
      animations: layer.animations,
      anchor: {
        ...layer.anchor,
        position: { x: placement.x, y: placement.y },
        scale: layerScaleIsAspectLocked(layer.type) ? aspectLockedScale(requested) : requested,
        rotationDegrees: placement.rotationDegrees,
      },
    }]);
  }

  if (value.order) {
    const currentIds = document.layers.map((layer) => layer.id);
    if (value.order.length !== currentIds.length
      || new Set(value.order).size !== currentIds.length
      || currentIds.some((id) => !value.order!.includes(id))) {
      throw new Error(`order must contain every layer exactly once: ${currentIds.join(", ")}`);
    }
    value.order.forEach((layerId, index) => {
      document = applyStickerOperationsV1(document, [{ op: "reorderLayer", layerId, index }]);
    });
  }

  const parsed = StickerDocumentSchema.parse(document);
  const diagnostics = layoutDiagnostics(parsed);
  if (diagnostics.offCanvasLayerIds.length > 0) {
    throw new Error(
      `Keep every complete layer box on canvas. Fix: ${diagnostics.offCanvasLayerIds.join(", ")}`,
    );
  }
  return parsed;
}
