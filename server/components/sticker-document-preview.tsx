"use client";

import { useEffect, useState, type CSSProperties } from "react";
import type { StickerDocumentV1, StickerLayerV1 } from "@/lib/contracts/sticker";

type Timed = { timeSeconds: number };

function framePair<T extends Timed>(frames: T[], time: number): [T | undefined, T | undefined, number] {
  if (frames.length === 0) return [undefined, undefined, 0];
  const ordered = [...frames].sort((a, b) => a.timeSeconds - b.timeSeconds);
  const nextIndex = ordered.findIndex((frame) => frame.timeSeconds >= time);
  if (nextIndex <= 0) return [ordered[0], ordered[0], 0];
  if (nextIndex < 0) return [ordered.at(-1), ordered.at(-1), 0];
  const previous = ordered[nextIndex - 1];
  const next = ordered[nextIndex];
  return [previous, next, (time - previous.timeSeconds) / Math.max(next.timeSeconds - previous.timeSeconds, 0.001)];
}

function interpolate(a: number | undefined, b: number | undefined, progress: number, fallback: number): number {
  const start = a ?? fallback;
  return start + ((b ?? start) - start) * progress;
}

function layerStyle(layer: StickerLayerV1, time: number): CSSProperties {
  const [pa, pb, pp] = framePair(layer.animation.position, time);
  const [sa, sb, sp] = framePair(layer.animation.scale, time);
  const [ra, rb, rp] = framePair(layer.animation.rotation, time);
  const [oa, ob, op] = framePair(layer.animation.opacity, time);
  const [ea, eb, ep] = framePair(layer.animation.effects, time);
  const x = interpolate(pa?.x, pb?.x, pp, 0.5);
  const y = interpolate(pa?.y, pb?.y, pp, 0.5);
  const scaleX = interpolate(sa?.x, sb?.x, sp, 1);
  const scaleY = interpolate(sa?.y, sb?.y, sp, 1);
  const degrees = interpolate(ra?.degrees, rb?.degrees, rp, 0);
  const opacity = interpolate(oa?.value, ob?.value, op, 1);
  const blur = interpolate(ea?.blurRadius, eb?.blurRadius, ep, 0);
  const hue = interpolate(ea?.hueDegrees, eb?.hueDegrees, ep, 0);
  const saturation = interpolate(ea?.saturation, eb?.saturation, ep, 1);
  return {
    left: `${x * 100}%`, top: `${y * 100}%`, opacity: layer.hidden ? 0 : opacity,
    transform: `translate(-50%, -50%) rotate(${degrees}deg) scale(${scaleX}, ${scaleY})`,
    filter: `blur(${blur}px) hue-rotate(${hue}deg) saturate(${saturation})`,
  };
}

function Shape({ layer }: { layer: Extract<StickerLayerV1, { type: "shape" }> }) {
  const glyph = layer.shape === "star" ? "★" : layer.shape === "heart" ? "♥" : layer.shape === "burst" ? "✦" : "";
  return glyph ? <span className="scene-shape-glyph" style={{ color: layer.fill }}>{glyph}</span>
    : <span className={`scene-shape scene-shape-${layer.shape}`} style={{ background: layer.fill, borderColor: layer.stroke }} />;
}

export function StickerDocumentPreview({ document, assetUrls, label, repeats = false }: {
  document: StickerDocumentV1;
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
      {layer.type === "text" && <span className={`scene-text scene-font-${layer.font}`} style={{ color: layer.color, fontWeight: layer.weight }}>{layer.text}</span>}
      {layer.type === "shape" && <Shape layer={layer} />}
      {layer.type === "particle" && <span className="scene-particles">{Array.from({ length: Math.min(layer.count, 24) }, (_, index) => <i style={{ left: `${(layer.seed + index * 37) % 100}%`, top: `${(layer.seed * 3 + index * 61) % 100}%`, color: layer.color }} key={index}>{layer.preset === "hearts" ? "♥" : layer.preset === "bubbles" ? "○" : "✦"}</i>)}</span>}
    </div>)}
  </div>;
}
