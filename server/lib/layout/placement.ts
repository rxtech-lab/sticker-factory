import {
  applyStickerOperationsV1,
  type StickerDocument,
} from "@/lib/contracts/sticker";
import type { NormalizedRect, SubjectBounds } from "@/lib/images/subject-bounds";
import { LAYER_FIT, layerBounds, layerBoxCoverage, type Bounds } from "@/lib/layout/composition";

/** A resting position and size, the two halves of an anchor that layout decides. */
export type Placement = {
  position: { x: number; y: number };
  scale: { x: number; y: number };
};

/**
 * Below this much of the frame a measured subject is a stray pixel, not a part; above it the model
 * returned the whole composition instead of one element separated from it. Either way the plan's
 * own layout is the better guess.
 */
const MIN_PLAUSIBLE_COVERAGE = 0.02;
const MAX_PLAUSIBLE_COVERAGE = 0.9;

/**
 * The anchor implied by where a separated part landed in the frame it was cut from.
 *
 * A part separated from an approved reference at its original position and size is, by the bounds
 * of what survived, a statement of where it belongs on the canvas: the reference *is* the canvas.
 * The stored PNG is the measured `crop` square, so the layer box maps onto exactly that rectangle
 * of the frame — its centre is the position, and its side over the renderer's fit box is the scale.
 *
 * Returns `undefined` when the measurement cannot be trusted, and the plan's layout should stand.
 */
export function placementFromSubject(subject: SubjectBounds | undefined): Placement | undefined {
  if (!subject) return undefined;
  if (subject.source.width !== subject.source.height) return undefined;
  if (subject.coverage < MIN_PLAUSIBLE_COVERAGE || subject.coverage > MAX_PLAUSIBLE_COVERAGE) {
    return undefined;
  }
  const side = Math.min(1, subject.crop.width / LAYER_FIT);
  if (side < 0.05) return undefined;
  return {
    position: {
      x: subject.crop.left + subject.crop.width / 2,
      y: subject.crop.top + subject.crop.height / 2,
    },
    scale: { x: side, y: side },
  };
}

/** Intersection over union of two frame rectangles. */
export function rectOverlapRatio(a: NormalizedRect, b: NormalizedRect): number {
  const width = Math.max(0, Math.min(a.left + a.width, b.left + b.width) - Math.max(a.left, b.left));
  const height = Math.max(0, Math.min(a.top + a.height, b.top + b.height) - Math.max(a.top, b.top));
  const intersection = width * height;
  const union = a.width * a.height + b.width * b.height - intersection;
  return union > 0 ? intersection / union : 0;
}

/**
 * Measured placements for the parts of one build, minus the ones the separation visibly failed on.
 *
 * Two parts that came back occupying the same square were not separated: the model returned the
 * whole design, or the same element, for both. Neither measurement says anything about where its
 * part belongs, so both fall back to the plan rather than landing on top of each other.
 */
export function measuredPlacements(
  parts: ReadonlyArray<{ layerId: string; subject: SubjectBounds | undefined }>,
): Map<string, Placement> {
  const placements = new Map<string, Placement>();
  const crops = new Map<string, NormalizedRect>();
  for (const part of parts) {
    const placement = placementFromSubject(part.subject);
    if (!placement || !part.subject) continue;
    placements.set(part.layerId, placement);
    crops.set(part.layerId, part.subject.crop);
  }
  const duplicates = new Set<string>();
  const ids = [...crops.keys()];
  for (let first = 0; first < ids.length; first += 1) {
    for (let second = first + 1; second < ids.length; second += 1) {
      if (rectOverlapRatio(crops.get(ids[first])!, crops.get(ids[second])!) > 0.9) {
        duplicates.add(ids[first]);
        duplicates.add(ids[second]);
      }
    }
  }
  for (const id of duplicates) placements.delete(id);
  return placements;
}

/**
 * Moves layers to their measured placements, keeping everything else about them.
 *
 * Goes through `setLayerAnimations` rather than writing the anchor directly: the anchor is only
 * half of a positioned layer, and the document refuses a layer whose compiled keyframes disagree
 * with it. Recompiling from the same specs is what keeps the two halves together.
 */
export function applyMeasuredPlacements(
  document: StickerDocument,
  placements: ReadonlyMap<string, Placement>,
): StickerDocument {
  if (placements.size === 0) return document;
  return applyStickerOperationsV1(document, document.layers.flatMap((layer) => {
    const placement = placements.get(layer.id);
    if (!placement) return [];
    return [{
      op: "setLayerAnimations" as const,
      layerId: layer.id,
      animations: layer.animations,
      anchor: { ...layer.anchor, position: placement.position, scale: placement.scale },
    }];
  }));
}

/** Scales tried for a new layer, largest first: a fresh element should be as visible as the room allows. */
const FREE_PLACEMENT_SCALES = [0.5, 0.4, 0.33, 0.25];

/** Candidate centres per axis. Odd, so the canvas centre is one of them. */
const FREE_PLACEMENT_STEPS = 5;

/**
 * Somewhere a new layer can go without covering what is already there.
 *
 * Deterministic on purpose: the same document always gets the same answer, so a replayed turn
 * lands its layer where the first attempt did. It tries each scale from largest to smallest over a
 * grid of centres whose box stays on canvas, and takes the first spot that overlaps nothing. When
 * every spot overlaps something — a full-frame hero leaves no free canvas — it takes the largest
 * scale's least-covering spot, which puts the new element over a corner rather than the middle.
 */
export function suggestFreePlacement(
  document: StickerDocument,
  options: { scales?: readonly number[] } = {},
): Placement {
  const scales = options.scales ?? FREE_PLACEMENT_SCALES;
  const occupied = document.layers
    .filter((layer) => !layer.hidden && layer.anchor.opacity > 0)
    .map((layer) => layerBounds(layer));
  if (occupied.length === 0) {
    const side = scales[0] ?? 1;
    return { position: { x: 0.5, y: 0.5 }, scale: { x: side, y: side } };
  }

  let best: { placement: Placement; score: number } | undefined;
  for (const side of scales) {
    const half = (LAYER_FIT * side) / 2;
    const candidates: Array<{ placement: Placement; score: number }> = [];
    for (let row = 0; row < FREE_PLACEMENT_STEPS; row += 1) {
      for (let column = 0; column < FREE_PLACEMENT_STEPS; column += 1) {
        const x = half + (1 - 2 * half) * (column / (FREE_PLACEMENT_STEPS - 1));
        const y = half + (1 - 2 * half) * (row / (FREE_PLACEMENT_STEPS - 1));
        const box: Bounds = { left: x - half, right: x + half, top: y - half, bottom: y + half };
        const score = Math.max(0, ...occupied.map((other) => layerBoxCoverage(box, other)));
        candidates.push({ placement: { position: { x, y }, scale: { x: side, y: side } }, score });
      }
    }
    const free = candidates.find((candidate) => candidate.score === 0);
    if (free) return free.placement;
    // Only the largest scale competes for the fallback: shrinking does not make a covered canvas
    // less covered, it only makes the new element harder to see.
    if (!best) {
      best = candidates.reduce((lowest, candidate) => (candidate.score < lowest.score ? candidate : lowest));
    }
  }
  return best!.placement;
}
