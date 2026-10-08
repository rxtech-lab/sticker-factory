"use client";

import { renderSVG } from "@/lib/controllable/sample";
import { useEffect, useState, type CSSProperties } from "react";
import { easedProgress } from "@/lib/animation/easing";
import type { StickerEasingV1 } from "@/lib/contracts/animation";
import type { PaintV2, StickerDocument, StickerLayerV1 } from "@/lib/contracts/sticker";

type Timed = { timeSeconds: number; easing: StickerEasingV1 };

/**
 * The two keyframes straddling `time`, and the eased blend between them.
 *
 * Easing comes off the *upper* keyframe, which is the convention the compiler emits against and
 * `AnimationInterpolator` reads. This preview used to blend linearly, so it disagreed with the
 * native renderer and the exporter on every eased segment — most visibly on springs, which overshoot
 * and settle here and simply ramped there.
 */
function framePair<T extends Timed>(frames: T[], time: number): [T | undefined, T | undefined, number] {
  if (frames.length === 0) return [undefined, undefined, 0];
  const ordered = [...frames].sort((a, b) => a.timeSeconds - b.timeSeconds);
  const nextIndex = ordered.findIndex((frame) => frame.timeSeconds >= time);
  if (nextIndex <= 0) return [ordered[0], ordered[0], 0];
  if (nextIndex < 0) return [ordered.at(-1), ordered.at(-1), 0];
  const previous = ordered[nextIndex - 1];
  const next = ordered[nextIndex];
  const progress = (time - previous.timeSeconds) / Math.max(next.timeSeconds - previous.timeSeconds, 0.001);
  return [previous, next, easedProgress(progress, next.easing)];
}

function interpolate(a: number | undefined, b: number | undefined, progress: number, fallback: number): number {
  const start = a ?? fallback;
  return start + ((b ?? start) - start) * progress;
}

/**
 * The document's angle convention as a CSS gradient angle.
 *
 * The document measures from the positive x-axis, CSS from "to top" clockwise. Shared by paints and
 * by the wipe/sheen sweeps so the two cannot drift apart — they did not agree the first time this
 * conversion was written twice.
 */
function cssAngle(angleDegrees: number): number {
  return angleDegrees + 90;
}

/**
 * The wipe mask and sheen overlay as CSS, or `undefined` when the channel is at rest.
 *
 * CSS `linear-gradient` sizes its axis to the box's corners, which is exactly what the native
 * `sweepUnitPoint` does, so an angled wipe lines up across the two renderers. Percentages are
 * clamped and re-sorted for the same reason the Swift side does it: a negative or descending stop
 * list is not a well-defined gradient anywhere.
 */
function sweepStops(stops: Array<[string, number]>): string {
  return stops
    .map(([color, location]) => [color, Math.min(Math.max(location, 0), 1)] as const)
    .sort((a, b) => a[1] - b[1])
    .map(([color, location]) => `${color} ${location * 100}%`)
    .join(", ");
}

function layerStyle(layer: StickerLayerV1, time: number): CSSProperties {
  const [pa, pb, pp] = framePair(layer.animation.position, time);
  const [sa, sb, sp] = framePair(layer.animation.scale, time);
  const [ra, rb, rp] = framePair(layer.animation.rotation, time);
  const [oa, ob, op] = framePair(layer.animation.opacity, time);
  const [ea, eb, ep] = framePair(layer.animation.effects, time);
  const [wa, wb, wp] = framePair(layer.animation.wipe, time);
  const [ga, gb, gp] = framePair(layer.animation.glow, time);
  const x = interpolate(pa?.x, pb?.x, pp, 0.5);
  const y = interpolate(pa?.y, pb?.y, pp, 0.5);
  const scaleX = interpolate(sa?.x, sb?.x, sp, 1);
  const scaleY = interpolate(sa?.y, sb?.y, sp, 1);
  const degrees = interpolate(ra?.degrees, rb?.degrees, rp, 0);
  const opacity = interpolate(oa?.value, ob?.value, op, 1);
  const blur = interpolate(ea?.blurRadius, eb?.blurRadius, ep, 0);
  const hue = interpolate(ea?.hueDegrees, eb?.hueDegrees, ep, 0);
  const saturation = interpolate(ea?.saturation, eb?.saturation, ep, 1);

  const wipeStart = interpolate(wa?.start, wb?.start, wp, 0);
  const wipeEnd = interpolate(wa?.end, wb?.end, wp, 1);
  const wipeAngle = interpolate(wa?.angleDegrees, wb?.angleDegrees, wp, 0);
  const softness = interpolate(wa?.softness, wb?.softness, wp, 0);
  const wiping = layer.animation.wipe.length > 0;
  const feather = softness / 2;
  const maskImage = !wiping
    ? undefined
    : wipeEnd <= wipeStart
      // A closed window hides the layer outright rather than inverting, matching `AnimatedWipe`.
      ? "linear-gradient(transparent 0%, transparent 100%)"
      : `linear-gradient(${cssAngle(wipeAngle)}deg, ${sweepStops([
        ["transparent", wipeStart - feather],
        ["#000", wipeStart + feather],
        ["#000", wipeEnd - feather],
        ["transparent", wipeEnd + feather],
      ])})`;

  // Bloom becomes a drop-shadow filter rather than a second blurred copy: it is the one CSS filter
  // that spreads a halo in the layer's own colours without needing the artwork drawn twice. It is a
  // softer, less additive look than the native `plusLighter` pass — an approximation, like the sheen
  // below — but it responds to the same `amount` and `radius` and reads as the same effect.
  const glowAmount = interpolate(ga?.amount, gb?.amount, gp, 0);
  const glowRadius = interpolate(ga?.radius, gb?.radius, gp, 0.08);
  const glowFilter = glowAmount > 0
    ? ` drop-shadow(0 0 ${glowRadius * 100}px rgba(255, 255, 255, ${glowAmount}))`
    : "";

  return {
    left: `${x * 100}%`, top: `${y * 100}%`, opacity: layer.hidden ? 0 : opacity,
    transform: `translate(-50%, -50%) rotate(${degrees}deg) scale(${scaleX}, ${scaleY})`,
    filter: `blur(${blur}px) hue-rotate(${hue}deg) saturate(${saturation})${glowFilter}`,
    maskImage,
    WebkitMaskImage: maskImage,
  };
}

/**
 * The travelling highlight, as an overlay sitting on top of the layer's own content.
 *
 * Knowingly looser than the native renderer, which clips the band to the artwork's alpha with
 * `sourceAtop`. Here it is clipped to the layer's *box*, so on non-rectangular artwork the highlight
 * runs over transparent corners too. Matching the native version would mean compositing against the
 * layer's alpha, which CSS cannot do without duplicating the content into a mask.
 */
function SheenOverlay({ layer, time }: { layer: StickerLayerV1; time: number }) {
  const [sa, sb, sp] = framePair(layer.animation.sheen, time);
  if (layer.animation.sheen.length === 0) return null;
  const intensity = interpolate(sa?.intensity, sb?.intensity, sp, 0);
  if (intensity <= 0) return null;
  const position = interpolate(sa?.position, sb?.position, sp, 0);
  const width = interpolate(sa?.width, sb?.width, sp, 0.25);
  const angle = interpolate(sa?.angleDegrees, sb?.angleDegrees, sp, 0);
  const half = width / 2;
  return <span
    className="scene-sheen"
    aria-hidden="true"
    style={{
      backgroundImage: `linear-gradient(${cssAngle(angle)}deg, ${sweepStops([
        ["rgba(255,255,255,0)", position - half],
        [`rgba(255,255,255,${intensity})`, position],
        ["rgba(255,255,255,0)", position + half],
      ])})`,
    }}
  />;
}

/**
 * A paint as a CSS value.
 *
 * Gradients become real CSS gradients rather than collapsing to a colour, since that is one of the
 * few places the web preview can match the native renderer exactly. The angle convention differs
 * though: CSS measures from "to top" clockwise, the document from the positive x-axis, hence the
 * 90-degree offset.
 */
function paintToCss(paint: PaintV2 | undefined): string | undefined {
  if (!paint) return undefined;
  switch (paint.type) {
  case "solid":
    return paint.color;
  case "linearGradient":
    return `linear-gradient(${paint.angleDegrees + 90}deg, ${paint.stops.map((stop) => `${stop.color} ${stop.location * 100}%`).join(", ")})`;
  case "radialGradient":
    return `radial-gradient(circle at ${paint.center.x * 100}% ${paint.center.y * 100}%, ${paint.stops.map((stop) => `${stop.color} ${stop.location * 100}%`).join(", ")})`;
  }
}

/** A paint's representative colour, for the places CSS takes a colour and not an image. */
function paintToColor(paint: PaintV2 | undefined): string | undefined {
  if (!paint) return undefined;
  return paint.type === "solid" ? paint.color : paint.stops[0]?.color;
}

function Shape({ layer }: { layer: Extract<StickerLayerV1, { type: "shape" }> }) {
  const kind = layer.shape.kind;
  const glyph = kind === "star" ? "★" : kind === "heart" ? "♥" : kind === "burst" ? "✦" : "";
  return glyph
    ? <span className="scene-shape-glyph" style={{ color: paintToColor(layer.fill) }}>{glyph}</span>
    : <span
      className={`scene-shape scene-shape-${kind}`}
      style={{ background: paintToCss(layer.fill), borderColor: paintToColor(layer.stroke?.paint) }}
    />;
}

export function StickerDocumentPreview({ document, assetUrls, label, repeats = false }: {
  document: StickerDocument;
  assetUrls: Record<string, string>;
  label: string;
  repeats?: boolean;
}) {
  const [time, setTime] = useState(0);
  useEffect(() => {
    if (document.kind !== "animated" || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const start = performance.now();
    let frame = 0;
    const tick = (now: number) => {
      const elapsed = (now - start) / 1000;
      const playbackLoop = repeats && document.loop === "once" ? "loop" : document.loop;
      const cycle = playbackLoop === "pingPong" ? document.durationSeconds * 2 : document.durationSeconds;
      const offset = playbackLoop === "once" ? Math.min(elapsed, document.durationSeconds) : elapsed % cycle;
      setTime(playbackLoop === "pingPong" && offset > document.durationSeconds ? cycle - offset : offset);
      if (playbackLoop !== "once" || elapsed < document.durationSeconds) frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [document, repeats]);

  return <div className="sticker-scene" role="img" aria-label={label}>
    {document.layers.map((layer) => <div className={`scene-layer scene-${layer.type}`} style={layerStyle(layer, time)} key={layer.id}>
      {layer.type === "image" && assetUrls[layer.assetId]
        // URLs are ownership-checked, short-lived R2 values supplied separately from the document.
        // eslint-disable-next-line @next/next/no-img-element
        ? <img src={assetUrls[layer.assetId]} alt="" className={`scene-image scene-image-${layer.contentMode}`} /> : null}
      {layer.type === "text" && <span className={`scene-text scene-font-${layer.font}`} style={{ color: paintToColor(layer.paint), fontWeight: layer.weight }}>{layer.text}</span>}
      {layer.type === "shape" && <Shape layer={layer} />}
      {layer.type === "svg" && layer.source.kind === "inline"
        // The markup passed `svgMarkupRejectionReason` on the way into the document — no scripts,
        // no remote references — which is what makes embedding it here safe.
        ? <span className="scene-svg" dangerouslySetInnerHTML={{ __html: layer.rig ? renderSVG(layer.rig, layer.svgState, time) : layer.source.markup }} />
        : null}
      {layer.type === "particle" && <span className="scene-particles">{Array.from({ length: Math.min(layer.count, 24) }, (_, index) => <i style={{ left: `${(layer.seed + index * 37) % 100}%`, top: `${(layer.seed * 3 + index * 61) % 100}%`, color: paintToColor(layer.paint) }} key={index}>{layer.preset === "hearts" ? "♥" : layer.preset === "bubbles" ? "○" : "✦"}</i>)}</span>}
      <SheenOverlay layer={layer} time={time} />
    </div>)}
  </div>;
}
