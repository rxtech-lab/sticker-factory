import type { ShapeKindV2 } from "@/lib/contracts/paint";

/**
 * SVG path data for each shape kind, in a 0–1 unit box.
 *
 * The real geometry lives in `AnimatedShape` on the Swift side and is what the exporter draws; this
 * is a second implementation, written because the server had no way to draw a shape at all. It is
 * deliberately an *approximation for review*: the curves here are close enough to judge layout,
 * balance and motion, not to compare pixel for pixel against an export.
 *
 * Everything is emitted in a unit box so the caller can scale it to whatever the layer's fit box is,
 * exactly as `cornerRadius` and `stroke.width` are already expressed as fractions.
 */

const round = (value: number) => Math.round(value * 10_000) / 10_000;

function polygonPath(sides: number, rotationOffset = -Math.PI / 2): string {
  const points = Array.from({ length: sides }, (_, index) => {
    const angle = rotationOffset + (index * 2 * Math.PI) / sides;
    return `${round(0.5 + 0.5 * Math.cos(angle))},${round(0.5 + 0.5 * Math.sin(angle))}`;
  });
  return `M${points.join("L")}Z`;
}

function starPath(points: number, innerRatio: number): string {
  const steps = points * 2;
  const coordinates = Array.from({ length: steps }, (_, index) => {
    const radius = index % 2 === 0 ? 0.5 : 0.5 * innerRatio;
    const angle = -Math.PI / 2 + (index * Math.PI) / points;
    return `${round(0.5 + radius * Math.cos(angle))},${round(0.5 + radius * Math.sin(angle))}`;
  });
  return `M${coordinates.join("L")}Z`;
}

/**
 * A heart, as two arcs meeting at a bottom point.
 *
 * Written out rather than derived: the classic cubic heart is the one shape where a formula is
 * harder to read than the curve it produces.
 */
const HEART_PATH =
  "M0.5,0.92 C0.2,0.72 0.02,0.54 0.02,0.34 C0.02,0.16 0.16,0.05 0.31,0.05 "
  + "C0.4,0.05 0.47,0.1 0.5,0.17 C0.53,0.1 0.6,0.05 0.69,0.05 "
  + "C0.84,0.05 0.98,0.16 0.98,0.34 C0.98,0.54 0.8,0.72 0.5,0.92 Z";

/** A burst: a many-pointed star with a deep notch, which is what reads as a comic-book pop. */
const BURST_PATH = starPath(12, 0.62);

export type ShapeGeometry =
  | { kind: "path"; d: string }
  /** Kept as a primitive so the renderer can use exact SVG rounding rather than approximating it. */
  | { kind: "rect"; cornerRadius: number }
  | { kind: "ellipse" };

export function shapeGeometry(shape: ShapeKindV2, cornerRadius: number): ShapeGeometry {
  switch (shape.kind) {
  case "circle":
    return { kind: "ellipse" };
  case "roundedRectangle":
    return { kind: "rect", cornerRadius };
  case "capsule":
    // A capsule is a rect whose corners are as round as the box allows.
    return { kind: "rect", cornerRadius: 0.5 };
  case "triangle":
    return { kind: "path", d: "M0.5,0 L1,1 L0,1 Z" };
  case "heart":
    return { kind: "path", d: HEART_PATH };
  case "burst":
    return { kind: "path", d: BURST_PATH };
  case "star":
    return { kind: "path", d: starPath(shape.points, shape.innerRatio) };
  case "polygon":
    return { kind: "path", d: polygonPath(shape.sides) };
  case "path":
    // Author-supplied data, already length-capped by the schema. It is drawn in its own coordinate
    // space, so the renderer fits it by measuring rather than by assuming a unit box.
    return { kind: "path", d: shape.d };
  }
}

/** The glyph a particle preset scatters. Mirrors the browser preview so the two agree. */
export function particleGlyph(preset: "sparkles" | "confetti" | "hearts" | "bubbles" | "snow"): string {
  switch (preset) {
  case "hearts": return "♥";
  case "bubbles": return "○";
  case "snow": return "❄";
  case "confetti": return "◆";
  case "sparkles": return "✦";
  }
}

/**
 * Where a particle sits, as a fraction of the canvas.
 *
 * The same arithmetic the browser preview uses, so a document scattered one way there is scattered
 * the same way here. It is not the Swift field's algorithm — that one is a hash-driven simulation
 * with motion — so particle *placement* is the least faithful part of this renderer.
 */
export function particlePosition(seed: number, index: number): { x: number; y: number } {
  return {
    x: ((seed + index * 37) % 100) / 100,
    y: ((seed * 3 + index * 61) % 100) / 100,
  };
}
