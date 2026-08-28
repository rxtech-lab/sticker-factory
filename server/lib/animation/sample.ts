import { easedProgress } from "@/lib/animation/easing";
import { DEFAULT_TRIM, type StickerEasingV1 } from "@/lib/contracts/animation";
import type { StickerLayerV1 } from "@/lib/contracts/sticker";

/**
 * Sampling compiled keyframes at an instant, shared by everything that draws a document in
 * TypeScript.
 *
 * There are two such consumers — the browser preview and the server-side renderer the agent reviews
 * its own work through — and they must agree, or the agent would be refining a picture the user
 * never sees. Both used to be impossible to reconcile because the preview kept its sampling inline.
 *
 * This is a port of `AnimationInterpolator` on the Swift side, and follows the same two rules:
 * easing is read from the *upper* keyframe of the pair being blended, and a channel with no
 * keyframes resolves to the layer's anchor rather than to zero.
 */

type Timed = { timeSeconds: number; easing: StickerEasingV1 };

/** The two keyframes straddling `time`, and the eased blend between them. */
export function framePair<T extends Timed>(frames: readonly T[], time: number): [T | undefined, T | undefined, number] {
  if (frames.length === 0) return [undefined, undefined, 0];
  const ordered = [...frames].sort((a, b) => a.timeSeconds - b.timeSeconds);
  const nextIndex = ordered.findIndex((frame) => frame.timeSeconds >= time);
  // Past the last keyframe the value clamps, which is what makes a finished animation hold.
  if (nextIndex < 0) return [ordered.at(-1), ordered.at(-1), 0];
  if (nextIndex === 0) return [ordered[0], ordered[0], 0];
  const previous = ordered[nextIndex - 1];
  const next = ordered[nextIndex];
  const progress = (time - previous.timeSeconds) / Math.max(next.timeSeconds - previous.timeSeconds, 0.001);
  return [previous, next, easedProgress(progress, next.easing)];
}

export function interpolate(a: number | undefined, b: number | undefined, progress: number, fallback: number): number {
  const start = a ?? fallback;
  return start + ((b ?? start) - start) * progress;
}

/** Everything needed to draw one layer at one instant. */
export type LayerState = {
  position: { x: number; y: number };
  scale: { x: number; y: number };
  rotationDegrees: number;
  opacity: number;
  effects: { blurRadius: number; hueDegrees: number; saturation: number };
  trim: { start: number; end: number };
  wipe: { start: number; end: number; angleDegrees: number; softness: number };
  sheen: { position: number; width: number; angleDegrees: number; intensity: number };
  glow: { amount: number; radius: number };
};

export function sampleLayerState(layer: StickerLayerV1, time: number): LayerState {
  const animation = layer.animation;
  const anchor = layer.anchor;
  const resting = anchor.trim ?? DEFAULT_TRIM;

  const [pa, pb, pp] = framePair(animation.position, time);
  const [sa, sb, sp] = framePair(animation.scale, time);
  const [ra, rb, rp] = framePair(animation.rotation, time);
  const [oa, ob, op] = framePair(animation.opacity, time);
  const [ea, eb, ep] = framePair(animation.effects, time);
  const [ta, tb, tp] = framePair(animation.trim, time);
  const [wa, wb, wp] = framePair(animation.wipe, time);
  const [ha, hb, hp] = framePair(animation.sheen, time);
  const [ga, gb, gp] = framePair(animation.glow, time);

  return {
    position: {
      x: interpolate(pa?.x, pb?.x, pp, anchor.position.x),
      y: interpolate(pa?.y, pb?.y, pp, anchor.position.y),
    },
    scale: {
      x: interpolate(sa?.x, sb?.x, sp, anchor.scale.x),
      y: interpolate(sa?.y, sb?.y, sp, anchor.scale.y),
    },
    rotationDegrees: interpolate(ra?.degrees, rb?.degrees, rp, anchor.rotationDegrees),
    opacity: interpolate(oa?.value, ob?.value, op, anchor.opacity),
    effects: {
      blurRadius: interpolate(ea?.blurRadius, eb?.blurRadius, ep, 0),
      hueDegrees: interpolate(ea?.hueDegrees, eb?.hueDegrees, ep, 0),
      saturation: interpolate(ea?.saturation, eb?.saturation, ep, 1),
    },
    trim: {
      start: interpolate(ta?.start, tb?.start, tp, resting.start),
      end: interpolate(ta?.end, tb?.end, tp, resting.end),
    },
    // The three v3 channels have no anchor, so an empty one resolves to its own identity.
    wipe: {
      start: interpolate(wa?.start, wb?.start, wp, 0),
      end: interpolate(wa?.end, wb?.end, wp, 1),
      angleDegrees: interpolate(wa?.angleDegrees, wb?.angleDegrees, wp, 0),
      softness: interpolate(wa?.softness, wb?.softness, wp, 0),
    },
    sheen: {
      position: interpolate(ha?.position, hb?.position, hp, 0),
      width: interpolate(ha?.width, hb?.width, hp, 0.25),
      angleDegrees: interpolate(ha?.angleDegrees, hb?.angleDegrees, hp, 0),
      intensity: interpolate(ha?.intensity, hb?.intensity, hp, 0),
    },
    glow: {
      amount: interpolate(ga?.amount, gb?.amount, gp, 0),
      radius: interpolate(ga?.radius, gb?.radius, gp, 0.08),
    },
  };
}

/**
 * Wall-clock seconds mapped into the authored timeline, honouring `loop`.
 *
 * Mirrors `AnimationInterpolator.mappedTime`. `speed` is deliberately not applied: callers that
 * already hold a document time — a filmstrip picking instants to draw — would have it applied twice.
 */
export function loopedTime(
  time: number,
  timing: { durationSeconds: number; loop: "once" | "loop" | "pingPong" },
): number {
  const duration = Math.max(timing.durationSeconds, 0.0001);
  if (timing.loop === "once") return Math.min(Math.max(time, 0), duration);
  const cycle = timing.loop === "pingPong" ? duration * 2 : duration;
  const offset = ((time % cycle) + cycle) % cycle;
  return timing.loop === "pingPong" && offset > duration ? cycle - offset : offset;
}
