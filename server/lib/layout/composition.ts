import { z } from "zod";
import {
  applyStickerOperationsV1,
  aspectLockedScale,
  effectiveLayerScale,
  layerScaleIsAspectLocked,
  LayerIdSchema,
  MAX_LAYER_INDEX,
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
  placements: z.array(LayoutPlacementSchema).max(MAX_LAYER_INDEX + 1).optional(),
  /** Complete back-to-front layer order. A full permutation avoids ambiguous partial reorders. */
  order: z.array(LayerIdSchema).max(MAX_LAYER_INDEX + 1).optional(),
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

/** A layer's footprint in canvas fractions. */
export type Bounds = {
  left: number;
  right: number;
  top: number;
  bottom: number;
};

/**
 * The square every layer is drawn into before its scale is applied, as a fraction of the canvas.
 *
 * The one number the server renderer, the layout geometry, and the native renderer
 * (`AnimatedIconFrame.layerFit`) all have to agree on: a placement is meaningless unless the box it
 * describes is the box that gets drawn.
 */
export const LAYER_FIT = 0.86;

/** Conservative rotated bounds for the same square layer box the native/server renderers use. */
function boundsFor(
  type: StickerDocument["layers"][number]["type"],
  position: { x: number; y: number },
  rawScale: { x: number; y: number },
  rotationDegrees: number,
): Bounds {
  const radians = (rotationDegrees * Math.PI) / 180;
  const cosine = Math.abs(Math.cos(radians));
  const sine = Math.abs(Math.sin(radians));
  const scale = effectiveLayerScale(type, rawScale);
  const halfWidth = (LAYER_FIT / 2) * (cosine * scale.x + sine * scale.y);
  const halfHeight = (LAYER_FIT / 2) * (sine * scale.x + cosine * scale.y);
  return {
    left: position.x - halfWidth,
    right: position.x + halfWidth,
    top: position.y - halfHeight,
    bottom: position.y + halfHeight,
  };
}

export function layerBounds(layer: StickerDocument["layers"][number]): Bounds {
  return boundsFor(layer.type, layer.anchor.position, layer.anchor.scale, layer.anchor.rotationDegrees);
}

/**
 * The layer's box on the timeline's last frame.
 *
 * A channel with no keyframes sits at the anchor, and one that has them clamps to its final
 * keyframe past the end (see `lib/animation/compile`), so the last entry of each channel *is* the
 * resting state the sticker finishes in.
 */
function layerEndBounds(layer: StickerDocument["layers"][number]): { bounds: Bounds; opacity: number } {
  const last = <T>(track: readonly T[]): T | undefined => (track.length ? track[track.length - 1] : undefined);
  const position = last(layer.animation.position) ?? layer.anchor.position;
  const scale = last(layer.animation.scale) ?? layer.anchor.scale;
  const rotation = last(layer.animation.rotation)?.degrees ?? layer.anchor.rotationDegrees;
  const opacity = last(layer.animation.opacity)?.value ?? layer.anchor.opacity;
  return { bounds: boundsFor(layer.type, position, scale, rotation), opacity };
}

/** How much of the smaller of two boxes the other one covers, 0 when they are apart. */
export function layerBoxCoverage(a: Bounds, b: Bounds): number {
  const width = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
  const height = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  if (width === 0 || height === 0) return 0;
  const areaA = (a.right - a.left) * (a.bottom - a.top);
  const areaB = (b.right - b.left) * (b.bottom - b.top);
  const smaller = Math.min(areaA, areaB);
  return smaller > 0 ? (width * height) / smaller : 0;
}

/**
 * Slack for a box that sits exactly on the edge. Positions are sums of fractions, and a layer
 * pushed flush against the canvas by arithmetic lands a few ulps past it; that is not off canvas.
 */
const EDGE_TOLERANCE = 1e-6;

function boundsLeaveCanvas(box: Bounds): boolean {
  return box.left < -EDGE_TOLERANCE
    || box.right > 1 + EDGE_TOLERANCE
    || box.top < -EDGE_TOLERANCE
    || box.bottom > 1 + EDGE_TOLERANCE;
}

export type LayoutDiagnostics = {
  offCanvasLayerIds: string[];
  /**
   * Layers that finish the loop still visible but outside the canvas.
   *
   * Kept apart from `offCanvasLayerIds` because the two have different cures. That list is about
   * *resting* placement, which a layout placement fixes by moving the anchor; this one is about
   * motion, which a placement cannot reach — the layer has to be given a destination back inside
   * the frame instead.
   *
   * Opacity is what separates a bug from an exit. `slideOut` and `fadeOut` legitimately finish off
   * canvas, but they finish at zero opacity, so nothing pops. A layer that is still *visible* out
   * there is the reported artifact: it travels past the edge, the loop clock wraps, and it snaps
   * back to where it started.
   */
  motionLeavesCanvasLayerIds: string[];
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
  const offCanvasLayerIds = visible.flatMap((layer) => (
    boundsLeaveCanvas(bounds.get(layer.id)!) ? [layer.id] : []
  ));
  const motionLeavesCanvasLayerIds = visible.flatMap((layer) => {
    const end = layerEndBounds(layer);
    return end.opacity > 0 && boundsLeaveCanvas(end.bounds) ? [layer.id] : [];
  });
  const substantialOverlaps: LayoutDiagnostics["substantialOverlaps"] = [];
  for (let first = 0; first < visible.length; first += 1) {
    for (let second = first + 1; second < visible.length; second += 1) {
      const coverage = layerBoxCoverage(bounds.get(visible[first].id)!, bounds.get(visible[second].id)!);
      if (coverage === 0) continue;
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
  return { offCanvasLayerIds, motionLeavesCanvasLayerIds, substantialOverlaps };
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

/**
 * Brings every resting layer box back onto the canvas, touching nothing that already is.
 *
 * The last line of defence, not a layout tool: a reviewer that ran out of steps, or an edit that
 * bought an image and then placed it badly, must not ship a sticker with a layer hanging off the
 * edge. A box wider or taller than the canvas is shrunk uniformly to fit; then the centre is
 * shifted by however far the box overshoots. Rotation is left alone — the bounds already account
 * for it — and motion is recompiled so the keyframes follow the anchor.
 */
export function clampLayoutOnCanvas(document: StickerDocument): StickerDocument {
  const operations = document.layers.flatMap((layer) => {
    if (layer.hidden || layer.anchor.opacity <= 0) return [];
    let scale = layer.anchor.scale;
    let box = layerBounds(layer);
    if (!boundsLeaveCanvas(box)) return [];
    const width = box.right - box.left;
    const height = box.bottom - box.top;
    if (width > 1 || height > 1) {
      const factor = 1 / Math.max(width, height);
      scale = { x: scale.x * factor, y: scale.y * factor };
      box = layerBounds({ ...layer, anchor: { ...layer.anchor, scale } });
    }
    const dx = box.left < 0 ? -box.left : box.right > 1 ? 1 - box.right : 0;
    const dy = box.top < 0 ? -box.top : box.bottom > 1 ? 1 - box.bottom : 0;
    return [{
      op: "setLayerAnimations" as const,
      layerId: layer.id,
      animations: layer.animations,
      anchor: {
        ...layer.anchor,
        scale,
        position: { x: layer.anchor.position.x + dx, y: layer.anchor.position.y + dy },
      },
    }];
  });
  return operations.length === 0 ? document : applyStickerOperationsV1(document, operations);
}
