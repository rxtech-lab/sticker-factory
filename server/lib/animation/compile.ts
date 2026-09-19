import {
  ANIMATION_CHANNELS,
  CYCLIC_SPEC_TYPES,
  SPEC_CHANNELS,
  anchorTrim,
  type AnimationAnchorV1,
  type AnimationChannel,
  type AnimationSpecV1,
  type EffectKeyframeV1,
  type GlowKeyframeV1,
  type LayerAnimationV1,
  type OpacityKeyframeV1,
  type PositionKeyframeV1,
  type RotationKeyframeV1,
  type ScaleKeyframeV1,
  type SheenKeyframeV1,
  type TrimKeyframeV1,
  type WipeKeyframeV1,
} from "@/lib/contracts/animation";
import { easedProgress } from "@/lib/animation/easing";

/**
 * Compiles declarative animation specs into the keyframe tracks the renderer actually plays.
 *
 * Everything here is pure and deterministic — the same specs always produce byte-identical
 * keyframes — because `StickerDocument` stores both representations and asserts they agree. A
 * non-deterministic compiler would make that invariant unsatisfiable.
 *
 * Two renderer facts drive the whole design (see `StickerInterpolator.swift`):
 *
 *  1. Easing is read from the *upper* keyframe of the pair being blended, so a segment's easing
 *     belongs on its end keyframe, never its start.
 *  2. A channel with no keyframes falls back to a default (position 0.5,0.5 / scale 1,1 /
 *     rotation 0 / opacity 1), and values clamp outside the first and last keyframe. That is why
 *     an anchor equal to the default emits nothing, and why a delay simply means "no keyframe
 *     before this time".
 */

export type AnimationTiming = {
  kind: "static" | "animated";
  durationSeconds: number;
};

export class AnimationCompileError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AnimationCompileError";
  }
}

/** Document-wide keyframe ceiling, mirrored from `StickerDocumentSchema`. */
export const MAX_DOCUMENT_KEYFRAMES = 128;
/** Per-channel keyframe ceiling, mirrored from `LayerAnimationV1Schema`. */
export const MAX_CHANNEL_KEYFRAMES = 32;
/** Samples per cycle for the sine-driven specs. Four gives zero/peak/zero/trough. */
const SAMPLES_PER_CYCLE = 4;
/**
 * Segments an `arcTo` is sampled into; it emits one more keyframe than this.
 *
 * Eleven keyframes is a third of a channel's budget, which is the price of curving a channel the
 * interpolator blends linearly. It is enough that the chord error on the widest arc the schema
 * allows stays well under a pixel at export sizes, and few enough that eight arcing layers still
 * fit the document's 128-keyframe ceiling.
 */
const ARC_SEGMENTS = 10;
/**
 * The fraction of a `shine` cycle spent traversing; the remainder is an invisible return leg.
 *
 * A repeating sweep needs the band to jump back to the leading edge, and two keyframes cannot share
 * a timestamp. Reserving a slice at the end of each cycle — travelled at `intensity: 0`, so nothing
 * is on screen — is what lets `cycles > 1` exist without the discontinuity the interpolator cannot
 * express.
 */
const SHINE_SWEEP_FRACTION = 0.88;
/**
 * Where a `shine` reaches full brightness, as a fraction of its traverse, and its mirror.
 *
 * A triangular envelope (dark, peak at the midpoint, dark) reads as a brightening blob rather than a
 * travelling highlight. Holding full intensity across the middle of the traverse and ramping only at
 * the ends is what makes it read as a sweep.
 */
const SHINE_RAMP_FRACTION = 0.18;

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));
/**
 * Rounds, and normalises negative zero to positive zero.
 *
 * Both halves matter for the document invariant. Rounding kills float drift, and the `+ 0` kills
 * `-0`: `Math.sin(2 * Math.PI)` is a tiny negative number that rounds to `-0`, but `JSON.stringify`
 * writes `-0` as `"0"`. Without this, a stored track would read back as `0` and never deep-equal a
 * freshly compiled `-0`.
 */
const roundTime = (value: number) => Math.round(value * 10_000) / 10_000 + 0;
const roundValue = (value: number) => Math.round(value * 100_000) / 100_000 + 0;

type Channels = {
  position: PositionKeyframeV1[];
  scale: ScaleKeyframeV1[];
  rotation: RotationKeyframeV1[];
  opacity: OpacityKeyframeV1[];
  effects: EffectKeyframeV1[];
  trim: TrimKeyframeV1[];
  wipe: WipeKeyframeV1[];
  sheen: SheenKeyframeV1[];
  glow: GlowKeyframeV1[];
};

function emptyChannels(): Channels {
  return {
    position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
  };
}

const position = (t: number, x: number, y: number, easing: PositionKeyframeV1["easing"]): PositionKeyframeV1 => ({
  timeSeconds: roundTime(t),
  x: roundValue(clamp(x, -1, 2)),
  y: roundValue(clamp(y, -1, 2)),
  easing,
});

const scale = (t: number, x: number, y: number, easing: ScaleKeyframeV1["easing"]): ScaleKeyframeV1 => ({
  timeSeconds: roundTime(t),
  x: roundValue(clamp(x, 0.05, 8)),
  y: roundValue(clamp(y, 0.05, 8)),
  easing,
});

const rotation = (t: number, degrees: number, easing: RotationKeyframeV1["easing"]): RotationKeyframeV1 => ({
  timeSeconds: roundTime(t),
  degrees: roundValue(clamp(degrees, -1080, 1080)),
  easing,
});

const opacity = (t: number, value: number, easing: OpacityKeyframeV1["easing"]): OpacityKeyframeV1 => ({
  timeSeconds: roundTime(t),
  value: roundValue(clamp(value, 0, 1)),
  easing,
});

const effect = (
  t: number,
  parts: { blurRadius?: number; hueDegrees?: number; saturation?: number },
  easing: EffectKeyframeV1["easing"],
): EffectKeyframeV1 => ({
  timeSeconds: roundTime(t),
  blurRadius: roundValue(clamp(parts.blurRadius ?? 0, 0, 20)),
  hueDegrees: roundValue(clamp(parts.hueDegrees ?? 0, -180, 180)),
  saturation: roundValue(clamp(parts.saturation ?? 1, 0, 2)),
  easing,
});

const trim = (t: number, start: number, end: number, easing: TrimKeyframeV1["easing"]): TrimKeyframeV1 => ({
  timeSeconds: roundTime(t),
  start: roundValue(clamp(start, 0, 1)),
  end: roundValue(clamp(end, 0, 1)),
  easing,
});

const wipe = (
  t: number,
  start: number,
  end: number,
  angleDegrees: number,
  softness: number,
  easing: WipeKeyframeV1["easing"],
): WipeKeyframeV1 => ({
  timeSeconds: roundTime(t),
  start: roundValue(clamp(start, 0, 1)),
  end: roundValue(clamp(end, 0, 1)),
  angleDegrees: roundValue(clamp(angleDegrees, -360, 360)),
  softness: roundValue(clamp(softness, 0, 0.5)),
  easing,
});

const sheen = (
  t: number,
  position_: number,
  width: number,
  angleDegrees: number,
  intensity: number,
  easing: SheenKeyframeV1["easing"],
): SheenKeyframeV1 => ({
  timeSeconds: roundTime(t),
  // Clamped to the position channel's range, not 0…1: the band has to be representable fully
  // off-canvas at both ends or a sweep would start already at the layer's leading edge.
  position: roundValue(clamp(position_, -1, 2)),
  width: roundValue(clamp(width, 0.02, 1)),
  angleDegrees: roundValue(clamp(angleDegrees, -360, 360)),
  intensity: roundValue(clamp(intensity, 0, 1)),
  easing,
});

const glow = (t: number, amount: number, radius: number, easing: GlowKeyframeV1["easing"]): GlowKeyframeV1 => ({
  timeSeconds: roundTime(t),
  amount: roundValue(clamp(amount, 0, 1)),
  radius: roundValue(clamp(radius, 0.01, 0.5)),
  easing,
});

/**
 * Rejects two specs that write the same channel over overlapping time.
 *
 * There is no meaningful blend of "fade to 0" and "fade to 1" across one instant, and picking a
 * winner silently produces motion the author never asked for. Touching windows (one ends exactly
 * where the next begins) are allowed — that is the normal fade-in-then-fade-out shape, and the
 * duplicate boundary keyframe is reconciled in `mergeChannel`.
 */
function assertNoChannelConflicts(specs: readonly AnimationSpecV1[]): void {
  const windows = new Map<AnimationChannel, Array<{ spec: AnimationSpecV1; start: number; end: number }>>();
  for (const spec of specs) {
    for (const channel of SPEC_CHANNELS[spec.type]) {
      const list = windows.get(channel) ?? [];
      const start = spec.delay;
      const end = spec.delay + spec.duration;
      for (const existing of list) {
        if (start < existing.end && existing.start < end) {
          throw new AnimationCompileError(
            `Animations "${existing.spec.type}" and "${spec.type}" both drive the ${channel} channel `
            + `between ${Math.max(start, existing.start)}s and ${Math.min(end, existing.end)}s. `
            + "Give them non-overlapping delay/duration windows, or drop one.",
          );
        }
      }
      list.push({ spec, start, end });
      windows.set(channel, list);
    }
  }
}

/**
 * Folds a spec's keyframes into a channel, reconciling a shared boundary timestamp.
 *
 * Two keyframes may not sit on the same `timeSeconds` — the interpolator sorts by time and would
 * pick one arbitrarily. When windows merely touch and both sides agree on the value (fade in ending
 * at 1, fade out starting at 1) the duplicate is dropped. When they disagree it is a real
 * discontinuity that keyframes cannot express, so it is an error rather than a silent jump.
 */
function mergeChannel<Frame extends { timeSeconds: number }>(
  existing: Frame[],
  incoming: Frame[],
  channel: AnimationChannel,
): Frame[] {
  for (const frame of incoming) {
    const clash = existing.find((other) => other.timeSeconds === frame.timeSeconds);
    if (!clash) {
      existing.push(frame);
      continue;
    }
    const sameValue = JSON.stringify({ ...clash, easing: null }) === JSON.stringify({ ...frame, easing: null });
    if (!sameValue) {
      throw new AnimationCompileError(
        `Two animations set different ${channel} values at ${frame.timeSeconds}s. `
        + "Separate them in time so one finishes before the other starts.",
      );
    }
  }
  return existing.sort((a, b) => a.timeSeconds - b.timeSeconds);
}

/** Phase samples for a cyclic spec: 0, 0.25, ... cycles, inclusive of the closing sample. */
function cyclePhases(cycles: number): number[] {
  const phases: number[] = [];
  for (let step = 0; step <= cycles * SAMPLES_PER_CYCLE; step += 1) {
    phases.push(step / SAMPLES_PER_CYCLE);
  }
  return phases;
}

function compileSpec(spec: AnimationSpecV1, anchor: AnimationAnchorV1, cycleCap: number, out: Channels): void {
  const start = spec.delay;
  const end = spec.delay + spec.duration;
  const ease = spec.easing;
  const { position: anchorPosition, scale: anchorScale, rotationDegrees: anchorRotation, opacity: anchorOpacity } = anchor;
  const resting = anchorTrim(anchor);

  switch (spec.type) {
  case "fadeIn":
    mergeChannel(out.opacity, [opacity(start, 0, "linear"), opacity(end, anchorOpacity, ease)], "opacity");
    return;
  case "fadeOut":
    mergeChannel(out.opacity, [opacity(start, anchorOpacity, "linear"), opacity(end, 0, ease)], "opacity");
    return;
  case "popIn":
    mergeChannel(out.scale, [
      scale(start, anchorScale.x * spec.from, anchorScale.y * spec.from, "linear"),
      scale(end, anchorScale.x, anchorScale.y, ease),
    ], "scale");
    mergeChannel(out.opacity, [opacity(start, 0, "linear"), opacity(end, anchorOpacity, ease)], "opacity");
    return;
  case "popOut":
    mergeChannel(out.scale, [
      scale(start, anchorScale.x, anchorScale.y, "linear"),
      scale(end, anchorScale.x * spec.to, anchorScale.y * spec.to, ease),
    ], "scale");
    mergeChannel(out.opacity, [opacity(start, anchorOpacity, "linear"), opacity(end, 0, ease)], "opacity");
    return;
  case "slideIn":
  case "slideOut": {
    const entering = spec.type === "slideIn";
    // `directionOffset` names the direction of *travel*, so it answers "where does a slide that
    // ends up moving this way begin?" — the side opposite the motion. That is exactly the
    // off-canvas point an entrance starts from, but the mirror image of where an exit belongs:
    // `slideOut("right")` has to finish to the *right* of the anchor. Negating the distance for the
    // exiting case flips the offset to the far side and keeps one direction convention for both.
    const offset = directionOffset(spec.direction, entering ? spec.distance : -spec.distance);
    const away = { x: anchorPosition.x + offset.x, y: anchorPosition.y + offset.y };
    mergeChannel(out.position, [
      entering
        ? position(start, away.x, away.y, "linear")
        : position(start, anchorPosition.x, anchorPosition.y, "linear"),
      entering
        ? position(end, anchorPosition.x, anchorPosition.y, ease)
        : position(end, away.x, away.y, ease),
    ], "position");
    mergeChannel(out.opacity, [
      opacity(start, entering ? 0 : anchorOpacity, "linear"),
      opacity(end, entering ? anchorOpacity : 0, ease),
    ], "opacity");
    return;
  }
  case "moveTo":
    mergeChannel(out.position, [
      position(start, anchorPosition.x, anchorPosition.y, "linear"),
      position(end, spec.x, spec.y, ease),
    ], "position");
    return;
  case "arcTo": {
    const control = arcControlPoint(anchorPosition, spec, spec.arcHeight);
    const frames: PositionKeyframeV1[] = [];
    for (let index = 0; index <= ARC_SEGMENTS; index += 1) {
      const fraction = index / ARC_SEGMENTS;
      // Easing is baked into *where* each sample sits, and every keyframe is emitted linear, so the
      // interpolator replays the curve at the parameter speed the easing asked for. Putting the
      // easing on the segments instead would drop the velocity to zero at all eleven samples and
      // read as a stutter rather than a throw. The closing sample is pinned rather than eased so
      // an arc lands exactly on its target the way `moveTo` does, even under a spring's overshoot.
      //
      // The parameter is clamped rather than allowed to overshoot: a spring's easing exceeds 1, and
      // extrapolating a Bézier past its endpoint throws the layer clean off the canvas instead of
      // past its target. Clamped, a spring rings back and forth *along* the arc, which is what
      // "springy throw" should mean.
      const curve = clamp(index === ARC_SEGMENTS ? 1 : easedProgress(fraction, ease), 0, 1);
      const inverse = 1 - curve;
      const fromWeight = inverse * inverse;
      const controlWeight = 2 * inverse * curve;
      const toWeight = curve * curve;
      frames.push(position(
        start + fraction * spec.duration,
        fromWeight * anchorPosition.x + controlWeight * control.x + toWeight * spec.x,
        fromWeight * anchorPosition.y + controlWeight * control.y + toWeight * spec.y,
        "linear",
      ));
    }
    mergeChannel(out.position, frames, "position");
    return;
  }
  case "scaleTo":
    mergeChannel(out.scale, [
      scale(start, anchorScale.x, anchorScale.y, "linear"),
      scale(end, spec.x, spec.y, ease),
    ], "scale");
    return;
  case "rotateTo":
    mergeChannel(out.rotation, [
      rotation(start, anchorRotation, "linear"),
      rotation(end, spec.degrees, ease),
    ], "rotation");
    return;
  case "spin":
    mergeChannel(out.rotation, [
      rotation(start, anchorRotation, "linear"),
      rotation(end, anchorRotation + 360 * spec.turns * (spec.direction === "cw" ? 1 : -1), ease),
    ], "rotation");
    return;
  case "wiggle": {
    const cycles = Math.min(spec.cycles, cycleCap);
    const step = spec.duration / cycles;
    mergeChannel(out.rotation, cyclePhases(cycles).map((phase) => rotation(
      start + phase * step,
      anchorRotation + spec.amplitudeDegrees * Math.sin(2 * Math.PI * phase),
      ease,
    )), "rotation");
    return;
  }
  case "pulse": {
    const cycles = Math.min(spec.cycles, cycleCap);
    const step = spec.duration / cycles;
    mergeChannel(out.scale, cyclePhases(cycles).map((phase) => {
      const wave = Math.sin(2 * Math.PI * phase);
      const factor = wave >= 0
        ? 1 + wave * (spec.maxScale - 1)
        : 1 + wave * (1 - spec.minScale);
      return scale(start + phase * step, anchorScale.x * factor, anchorScale.y * factor, ease);
    }), "scale");
    return;
  }
  case "float": {
    const cycles = Math.min(spec.cycles, cycleCap);
    const step = spec.duration / cycles;
    mergeChannel(out.position, cyclePhases(cycles).map((phase) => position(
      start + phase * step,
      anchorPosition.x,
      // Negative y is up: the canvas origin is top-left.
      anchorPosition.y - spec.amplitude * Math.sin(2 * Math.PI * phase),
      ease,
    )), "position");
    return;
  }
  case "bounce": {
    const bounces = Math.min(spec.bounces, cycleCap);
    const step = spec.duration / bounces;
    const frames: PositionKeyframeV1[] = [position(start, anchorPosition.x, anchorPosition.y, "linear")];
    for (let index = 0; index < bounces; index += 1) {
      // Each hop is weaker than the last, which is what reads as gravity rather than a sine wave.
      const height = spec.height * Math.pow(0.6, index);
      frames.push(position(start + (index + 0.5) * step, anchorPosition.x, anchorPosition.y - height, "easeOut"));
      frames.push(position(start + (index + 1) * step, anchorPosition.x, anchorPosition.y, "easeIn"));
    }
    mergeChannel(out.position, frames, "position");
    return;
  }
  case "blurIn":
    mergeChannel(out.effects, [
      effect(start, { blurRadius: spec.radius }, "linear"),
      effect(end, { blurRadius: 0 }, ease),
    ], "effects");
    return;
  case "blurOut":
    mergeChannel(out.effects, [
      effect(start, { blurRadius: 0 }, "linear"),
      effect(end, { blurRadius: spec.radius }, ease),
    ], "effects");
    return;
  case "hueShift":
    mergeChannel(out.effects, [
      effect(start, { hueDegrees: 0 }, "linear"),
      effect(end, { hueDegrees: spec.degrees }, ease),
    ], "effects");
    return;
  case "drawOn":
    // Only `end` moves: the stroke grows from its own beginning to its full length.
    mergeChannel(out.trim, [
      trim(start, resting.start, spec.from, "linear"),
      trim(end, resting.start, resting.end, ease),
    ], "trim");
    return;
  case "drawOff":
    // Only `start` moves: the stroke is eaten from its beginning, so it reads as erasing rather
    // than as un-drawing backwards.
    mergeChannel(out.trim, [
      trim(start, resting.start, resting.end, "linear"),
      trim(end, spec.to, resting.end, ease),
    ], "trim");
    return;
  case "trimTo":
    mergeChannel(out.trim, [
      trim(start, resting.start, resting.end, "linear"),
      trim(end, spec.start, spec.end, ease),
    ], "trim");
    return;
  case "wipeIn": {
    // Only `end` moves: the visible window grows from the leading edge across the layer.
    const angle = wipeDirectionAngle(spec.direction);
    mergeChannel(out.wipe, [
      wipe(start, 0, 0, angle, spec.softness, "linear"),
      wipe(end, 0, 1, angle, spec.softness, ease),
    ], "wipe");
    return;
  }
  case "wipeOut": {
    // Only `start` moves, so the layer is eaten from the same edge the matching wipeIn revealed
    // from — it reads as the reveal running on rather than as it rewinding.
    const angle = wipeDirectionAngle(spec.direction);
    mergeChannel(out.wipe, [
      wipe(start, 0, 1, angle, spec.softness, "linear"),
      wipe(end, 1, 1, angle, spec.softness, ease),
    ], "wipe");
    return;
  }
  case "wipeTo":
    mergeChannel(out.wipe, [
      wipe(start, 0, 1, spec.angleDegrees, spec.softness, "linear"),
      wipe(end, spec.start, spec.end, spec.angleDegrees, spec.softness, ease),
    ], "wipe");
    return;
  case "shine": {
    const cycles = Math.min(spec.cycles, cycleCap);
    const step = spec.duration / cycles;
    // The band is centred on `position`, so half a width past each edge is exactly fully off-canvas.
    const from = -spec.width / 2;
    const span = 1 + spec.width;
    const frames: SheenKeyframeV1[] = [];
    for (let index = 0; index < cycles; index += 1) {
      const base = start + index * step;
      const traverse = SHINE_SWEEP_FRACTION * step;
      for (const phase of [0, SHINE_RAMP_FRACTION, 1 - SHINE_RAMP_FRACTION, 1]) {
        frames.push(sheen(
          base + phase * traverse,
          from + phase * span,
          spec.width,
          spec.angleDegrees,
          // Dark at both extremes, full brightness across the middle. The dark ends are also what
          // make the retreat to the next cycle's leading edge invisible.
          phase === 0 || phase === 1 ? 0 : spec.intensity,
          // Always linear, whatever the spec asked for. Easing the closing keyframe would decelerate
          // only the second half of the traverse, which reads as a stutter rather than a glint —
          // the same reason `arcTo` pins its samples.
          "linear",
        ));
      }
    }
    mergeChannel(out.sheen, frames, "sheen");
    return;
  }
  case "bloomIn":
    mergeChannel(out.glow, [
      glow(start, 0, spec.radius, "linear"),
      glow(end, spec.intensity, spec.radius, ease),
    ], "glow");
    return;
  case "bloomOut":
    mergeChannel(out.glow, [
      glow(start, spec.intensity, spec.radius, "linear"),
      glow(end, 0, spec.radius, ease),
    ], "glow");
    return;
  case "bloomPulse": {
    const cycles = Math.min(spec.cycles, cycleCap);
    const step = spec.duration / cycles;
    // Shaped like `bounce` rather than `pulse`: a glow only brightens, so sampling a full sine would
    // spend half of every cycle clamped flat at zero and cost twice the keyframes for the same
    // breathing motion.
    const frames: GlowKeyframeV1[] = [glow(start, 0, spec.radius, "linear")];
    for (let index = 0; index < cycles; index += 1) {
      frames.push(glow(start + (index + 0.5) * step, spec.intensity, spec.radius, ease));
      frames.push(glow(start + (index + 1) * step, 0, spec.radius, ease));
    }
    mergeChannel(out.glow, frames, "glow");
    return;
  }
  }
}

/**
 * The control point of the quadratic Bézier an `arcTo` follows.
 *
 * The apex sign is normalized rather than taken straight from the perpendicular: a raw perpendicular
 * flips with the direction of travel, so one `arcHeight` would arc a rightward throw over and a
 * leftward one under. Forcing the normal to point at the top of the canvas makes the sign mean the
 * same thing whichever way the layer is going, and leaves a purely vertical move — where "up" is
 * meaningless — bowing to the right.
 */
function arcControlPoint(
  from: { x: number; y: number },
  to: { x: number; y: number },
  arcHeight: number,
) {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  // `sqrt` rather than `Math.hypot`: hypot is not correctly rounded and implementations disagree,
  // which would break the byte-equality the Swift port has to hold to.
  const length = Math.sqrt(dx * dx + dy * dy);
  // A move that goes nowhere has no direction to be perpendicular to; straight up is the only
  // sensible reading, and it makes an in-place `arcTo` a toss that comes back down.
  let normalX = length > 0 ? dy / length : 0;
  let normalY = length > 0 ? -dx / length : -1;
  if (normalY > 0 || (normalY === 0 && normalX < 0)) {
    normalX = -normalX;
    normalY = -normalY;
  }
  // A quadratic Bézier passes half way to its control point at the midpoint of the curve, so the
  // control is displaced twice as far as the apex height the caller actually asked for.
  return {
    x: (from.x + to.x) / 2 + 2 * arcHeight * normalX,
    y: (from.y + to.y) / 2 + 2 * arcHeight * normalY,
  };
}

function directionOffset(direction: "up" | "down" | "left" | "right", distance: number) {
  switch (direction) {
  case "up": return { x: 0, y: distance };      // slides in from below, moving up
  case "down": return { x: 0, y: -distance };
  case "left": return { x: distance, y: 0 };    // slides in from the right, moving left
  case "right": return { x: -distance, y: 0 };
  }
}

/**
 * The wipe axis for a direction, in the paint convention: 0° left-to-right, increasing clockwise.
 *
 * Names the *direction of travel*, matching `directionOffset` — a `wipeIn` with direction `right`
 * uncovers the layer starting at its left edge and sweeps rightwards, the same way a `slideIn` with
 * direction `right` ends up travelling rightwards.
 */
function wipeDirectionAngle(direction: "up" | "down" | "left" | "right"): number {
  switch (direction) {
  case "right": return 0;
  case "down": return 90;
  case "left": return 180;
  case "up": return 270;
  }
}

/**
 * Emits the resting keyframe for channels no spec drives.
 *
 * Only channels whose anchor differs from the renderer's own default get a keyframe. Emitting all
 * six unconditionally would burn most of the 128-keyframe budget on layers that mostly just sit
 * where they were put.
 */
function applyAnchors(anchor: AnimationAnchorV1, driven: Set<AnimationChannel>, out: Channels): void {
  if (!driven.has("position") && (anchor.position.x !== 0.5 || anchor.position.y !== 0.5)) {
    out.position.push(position(0, anchor.position.x, anchor.position.y, "linear"));
  }
  if (!driven.has("scale") && (anchor.scale.x !== 1 || anchor.scale.y !== 1)) {
    out.scale.push(scale(0, anchor.scale.x, anchor.scale.y, "linear"));
  }
  if (!driven.has("rotation") && anchor.rotationDegrees !== 0) {
    out.rotation.push(rotation(0, anchor.rotationDegrees, "linear"));
  }
  if (!driven.has("opacity") && anchor.opacity !== 1) {
    out.opacity.push(opacity(0, anchor.opacity, "linear"));
  }
  const resting = anchorTrim(anchor);
  if (!driven.has("trim") && (resting.start !== 0 || resting.end !== 1)) {
    out.trim.push(trim(0, resting.start, resting.end, "linear"));
  }
}

export function countKeyframes(animation: LayerAnimationV1): number {
  // Driven off ANIMATION_CHANNELS rather than a hand-written sum, because every hand-written copy of
  // this list in the codebase has already drifted at least once — `trim` was missing from two of
  // them, which quietly failed a draw-on-only sticker at rendition acceptance.
  return ANIMATION_CHANNELS.reduce((total, channel) => total + animation[channel].length, 0);
}

/**
 * Compiles one layer's specs against its resting anchor.
 *
 * `cycleCap` is the budget lever: reducing the number of cycles degrades a wiggle from three
 * shakes to one but keeps it a wiggle, whereas reducing samples-per-cycle below four would sample
 * the sine only at its zero crossings and flatten the motion entirely.
 */
export function compileLayerAnimation(
  specs: readonly AnimationSpecV1[],
  anchor: AnimationAnchorV1,
  timing: AnimationTiming,
  cycleCap = Number.POSITIVE_INFINITY,
): LayerAnimationV1 {
  if (specs.length === 0) {
    const out = emptyChannels();
    applyAnchors(anchor, new Set(), out);
    return out;
  }
  if (timing.kind === "static") {
    throw new AnimationCompileError(
      `A static sticker cannot animate, but ${specs.length} animation(s) were supplied. `
      + "Create the sticker as animated, or remove the animations.",
    );
  }

  for (const spec of specs) {
    const end = spec.delay + spec.duration;
    if (end > timing.durationSeconds + 1e-9) {
      throw new AnimationCompileError(
        `Animation "${spec.type}" ends at ${roundTime(end)}s but the sticker is only `
        + `${timing.durationSeconds}s long. Shorten its duration, reduce its delay, or lengthen the sticker.`,
      );
    }
  }
  assertNoChannelConflicts(specs);

  const out = emptyChannels();
  const driven = new Set<AnimationChannel>();
  for (const spec of specs) {
    for (const channel of SPEC_CHANNELS[spec.type]) driven.add(channel);
  }
  for (const spec of specs) {
    compileSpec(spec, anchor, CYCLIC_SPEC_TYPES.has(spec.type) ? cycleCap : Number.POSITIVE_INFINITY, out);
  }
  applyAnchors(anchor, driven, out);

  for (const channel of ANIMATION_CHANNELS) {
    out[channel].sort((a, b) => a.timeSeconds - b.timeSeconds);
    if (out[channel].length > MAX_CHANNEL_KEYFRAMES) {
      throw new AnimationCompileError(
        `The ${channel} channel compiled to ${out[channel].length} keyframes, over the ${MAX_CHANNEL_KEYFRAMES} limit. `
        + "Use fewer cycles or fewer animations on this layer.",
      );
    }
  }
  return out;
}

export type LayerCompileInput = {
  layerId: string;
  specs: readonly AnimationSpecV1[];
  anchor: AnimationAnchorV1;
};

/**
 * Compiles every layer, shrinking cyclic specs until the document fits its keyframe budget.
 *
 * The cap is lowered uniformly rather than per-layer so the result stays independent of layer
 * order — the compiler has to be deterministic for the document invariant to hold.
 */
export function compileLayerAnimations(
  layers: readonly LayerCompileInput[],
  timing: AnimationTiming,
): LayerAnimationV1[] {
  const maxCycles = layers.reduce((highest, layer) => layer.specs.reduce((inner, spec) => (
    "cycles" in spec ? Math.max(inner, spec.cycles) : "bounces" in spec ? Math.max(inner, spec.bounces) : inner
  ), highest), 1);

  let lastError: AnimationCompileError | undefined;
  for (let cap = maxCycles; cap >= 1; cap -= 1) {
    try {
      const compiled = layers.map((layer) => compileLayerAnimation(layer.specs, layer.anchor, timing, cap));
      const total = compiled.reduce((sum, animation) => sum + countKeyframes(animation), 0);
      if (total <= MAX_DOCUMENT_KEYFRAMES) return compiled;
      lastError = new AnimationCompileError(
        `The animations compiled to ${total} keyframes, over the ${MAX_DOCUMENT_KEYFRAMES} limit for a document. `
        + "Use fewer layers, fewer animations per layer, or fewer cycles.",
      );
    } catch (error) {
      // A per-channel overflow may also clear up at a lower cycle cap, so keep shrinking; any other
      // failure (conflicts, timing) is invariant to the cap and rethrows immediately.
      if (!(error instanceof AnimationCompileError)) throw error;
      lastError = error;
      if (!error.message.includes("channel compiled to")) throw error;
    }
  }
  throw lastError ?? new AnimationCompileError("Animations could not be compiled within the keyframe budget");
}
