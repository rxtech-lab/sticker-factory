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
 * Which tile of a sequence layer's atlas is showing at a given document time.
 *
 * Deliberately a pure function of the *document* time — the value the renderer already holds, after
 * `speed` and after the document's own `loop` mapping. Three consequences, all of them the point:
 *
 * - `speed` scales the footage exactly as it scales keyframes. A sticker played at 2x plays
 *   everything at 2x, which is the only reading a user would predict, and it costs nothing.
 * - A ping-pong *document* plays real footage backwards on the way home, which is what turns 1.2s
 *   of Live Photo into a seamless 2.4s cycle with no visible cut. That is the ingest default.
 * - `durationSeconds` stays the sole authority on how long a sticker runs. Footage shorter than the
 *   cycle repeats according to its own `playback`; footage longer is simply truncated. The atlas
 *   never extends the document — which is exactly why `validateAnimatedRenditionTiming` needs no
 *   knowledge of sequence layers. Inverting this would be the tempting change, and would break it.
 *
 * Mirrored byte for byte by `AnimationInterpolator.sequenceFrameIndex` in Swift, and pinned from
 * both sides by `fixtures/sequence-frame-index-parity.json`.
 */
export function sequenceFrameIndex(
  layer: { frameCount: number; frameRate: number; playback: "loop" | "once" | "pingPong"; startSeconds: number },
  documentTime: number,
): number {
  const count = Math.max(1, Math.floor(layer.frameCount));
  if (count === 1) return 0;

  const elapsed = documentTime - layer.startSeconds;
  // Before the layer's start the first tile is held rather than the layer being hidden: a sequence
  // that vanished for its first second would look like a failed asset load, not like a delay.
  if (elapsed <= 0) return 0;

  const raw = Math.floor(elapsed * layer.frameRate);
  if (layer.playback === "once") return Math.min(raw, count - 1);
  if (layer.playback === "loop") return ((raw % count) + count) % count;

  const period = count * 2 - 2;
  const offset = ((raw % period) + period) % period;
  return offset < count ? offset : period - offset;
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
