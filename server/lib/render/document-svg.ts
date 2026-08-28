import { sampleLayerState, sequenceFrameIndex, type LayerState } from "@/lib/animation/sample";
import type { PaintV2, StrokeV2 } from "@/lib/contracts/paint";
import type { StickerDocument, StickerLayerV1 } from "@/lib/contracts/sticker";
import { particleGlyph, particlePosition, shapeGeometry } from "@/lib/render/shapes";

/**
 * Draws a `StickerDocument` as an SVG string.
 *
 * This exists so the agent can *look* at what it has built. Nothing else on the server has ever
 * needed to turn a document into pixels — the iOS client renders every export — so this is a second
 * renderer, and it is an approximation on purpose:
 *
 *   - shape geometry is re-derived here (see `shapes.ts`); the authoritative curves are Swift's
 *   - text is laid out by librsvg with whatever fonts the deploy image has, not by SwiftUI, so
 *     wrapping and metrics differ
 *   - particles are scattered by the browser preview's formula, not the Swift field's simulation
 *   - `sheen` is drawn as a plain band and `blendMode` is mapped only where SVG has an equivalent
 *
 * It is faithful enough for the things an agent actually needs to catch — a layer off-canvas, two
 * layers colliding, an entrance that has not started yet, a colour that reads wrong — and the tool
 * description says as much, so the model does not file bug reports about kerning.
 *
 * The layer box matches the native renderer's `AnimatedIconFrame.layerFit`. That constant has to
 * agree or every layer would be drawn at the wrong size relative to its own motion.
 */
const LAYER_FIT = 0.86;

/** Assets the document references, already fetched. Keyed by asset id. */
export type RenderAssets = Map<string, { bytes: Uint8Array; mimeType: string }>;

const escapeText = (value: string) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");

const round = (value: number) => Math.round(value * 1_000) / 1_000;

/** A counter so gradients and clips from different layers cannot collide on an id. */
class IdFactory {
  private next = 0;
  make(prefix: string): string {
    this.next += 1;
    return `${prefix}${this.next}`;
  }
}

function gradientDef(paint: PaintV2, id: string): string {
  const stops = (paint.type === "solid" ? [] : paint.stops)
    .map((stop) => `<stop offset="${round(stop.location)}" stop-color="${stop.color}"/>`)
    .join("");
  if (paint.type === "linearGradient") {
    // The document measures angles from the positive x-axis, clockwise; SVG's objectBoundingBox
    // vector is expressed the same way once y is flipped, so the angle maps straight across.
    const radians = (paint.angleDegrees * Math.PI) / 180;
    const dx = Math.cos(radians) / 2;
    const dy = Math.sin(radians) / 2;
    return `<linearGradient id="${id}" x1="${round(0.5 - dx)}" y1="${round(0.5 - dy)}" `
      + `x2="${round(0.5 + dx)}" y2="${round(0.5 + dy)}">${stops}</linearGradient>`;
  }
  if (paint.type === "radialGradient") {
    return `<radialGradient id="${id}" cx="${round(paint.center.x)}" cy="${round(paint.center.y)}" `
      + `r="${round(paint.radius)}">${stops}</radialGradient>`;
  }
  return "";
}

/** A paint as a `fill`/`stroke` value, plus any def it needs hoisted into `<defs>`. */
function paintValue(paint: PaintV2 | undefined, ids: IdFactory, defs: string[]): string {
  if (!paint) return "none";
  if (paint.type === "solid") return paint.color;
  const id = ids.make("p");
  defs.push(gradientDef(paint, id));
  return `url(#${id})`;
}

function strokeAttributes(stroke: StrokeV2 | undefined, box: number, ids: IdFactory, defs: string[]): string {
  if (!stroke) return "";
  // `width` is a fraction of the fit box, matching the contract's own wording.
  const width = stroke.width * box;
  const dash = stroke.dash.length > 0
    ? ` stroke-dasharray="${stroke.dash.map((value) => round(value * box)).join(" ")}"`
    : "";
  return ` stroke="${paintValue(stroke.paint, ids, defs)}" stroke-width="${round(width)}"`
    + ` stroke-linecap="${stroke.lineCap}" stroke-linejoin="${stroke.lineJoin}"${dash}`;
}

const FONT_STACKS: Record<string, string> = {
  rounded: "'SF Pro Rounded','Nunito','Quicksand',ui-rounded,system-ui,sans-serif",
  serif: "Georgia,'Times New Roman',serif",
  monospaced: "'SF Mono','DejaVu Sans Mono',monospace",
  system: "system-ui,'Helvetica Neue',Arial,sans-serif",
};

const FONT_WEIGHTS: Record<string, number> = { regular: 400, medium: 500, semibold: 600, bold: 700 };

/**
 * A filter chain for the effects channel plus bloom.
 *
 * `hue-rotate` and `saturate` are native SVG filter primitives, so those two are exact. Bloom is a
 * blurred copy composited back over the original, which is the same shape as the native
 * `plusLighter` pass even though SVG cannot express plus-lighter itself.
 */
function effectFilter(state: LayerState, box: number, id: string): string | undefined {
  const parts: string[] = [];
  const hasBlur = state.effects.blurRadius > 0.01;
  const hasHue = Math.abs(state.effects.hueDegrees) > 0.01;
  const hasSaturation = Math.abs(state.effects.saturation - 1) > 0.01;
  const hasGlow = state.glow.amount > 0.01;
  if (!hasBlur && !hasHue && !hasSaturation && !hasGlow) return undefined;

  let source = "SourceGraphic";
  if (hasBlur) {
    parts.push(`<feGaussianBlur in="${source}" stdDeviation="${round(state.effects.blurRadius)}" result="b"/>`);
    source = "b";
  }
  if (hasHue) {
    parts.push(`<feColorMatrix in="${source}" type="hueRotate" values="${round(state.effects.hueDegrees)}" result="h"/>`);
    source = "h";
  }
  if (hasSaturation) {
    parts.push(`<feColorMatrix in="${source}" type="saturate" values="${round(state.effects.saturation)}" result="s"/>`);
    source = "s";
  }
  if (hasGlow) {
    parts.push(
      `<feGaussianBlur in="${source}" stdDeviation="${round(state.glow.radius * box)}" result="g"/>`
      + `<feComponentTransfer in="g" result="ga">`
      + `<feFuncA type="linear" slope="${round(state.glow.amount)}"/></feComponentTransfer>`
      + `<feMerge><feMergeNode in="ga"/><feMergeNode in="${source}"/></feMerge>`,
    );
  }
  // A generous region, so a blur or a halo is not clipped at the layer's own bounds.
  return `<filter id="${id}" x="-50%" y="-50%" width="200%" height="200%" `
    + `filterUnits="objectBoundingBox">${parts.join("")}</filter>`;
}

/**
 * The wipe window as a gradient mask, matching `SweepGeometry.wipeStops` on the native side.
 *
 * `box` is load bearing. A `<mask>`'s content is in *user space*, so the rectangle carrying the
 * gradient has to be given the layer's real dimensions — a unit-sized rect masks the layer down to
 * a couple of pixels and the layer simply vanishes, which is exactly what it did the first time.
 * Sizing the rect to the box also makes the gradient's `objectBoundingBox` coordinates line up with
 * the wipe's own 0–1 window.
 */
function wipeMask(state: LayerState, id: string, box: number): string | undefined {
  const { start, end, softness, angleDegrees } = state.wipe;
  if (start <= 0 && end >= 1 && softness <= 0) return undefined;
  const radians = (angleDegrees * Math.PI) / 180;
  // The axis is extended to the box's corners, the same reason `sweepUnitPoint` exists natively:
  // an inscribed-circle axis leaves the corners of a diagonal wipe permanently masked out.
  const extent = Math.abs(Math.cos(radians)) + Math.abs(Math.sin(radians));
  const dx = (Math.cos(radians) * extent) / 2;
  const dy = (Math.sin(radians) * extent) / 2;
  const feather = softness / 2;
  const stops = end <= start
    ? [["#000", 0], ["#000", 1]] as const
    : ([
      ["#000", start - feather],
      ["#fff", start + feather],
      ["#fff", end - feather],
      ["#000", end + feather],
    ] as const);
  const body = stops
    .map(([color, location]) => [color, Math.min(Math.max(location, 0), 1)] as const)
    .sort((a, b) => a[1] - b[1])
    .map(([color, location]) => `<stop offset="${round(location)}" stop-color="${color}"/>`)
    .join("");
  const half = box / 2;
  return `<linearGradient id="${id}g" x1="${round(0.5 - dx)}" y1="${round(0.5 - dy)}" `
    + `x2="${round(0.5 + dx)}" y2="${round(0.5 + dy)}">${body}</linearGradient>`
    + `<mask id="${id}" maskUnits="userSpaceOnUse" x="${round(-half)}" y="${round(-half)}" `
    + `width="${round(box)}" height="${round(box)}">`
    + `<rect x="${round(-half)}" y="${round(-half)}" width="${round(box)}" height="${round(box)}" `
    + `fill="url(#${id}g)"/></mask>`;
}

function layerBody(
  layer: StickerLayerV1,
  state: LayerState,
  time: number,
  box: number,
  assets: RenderAssets,
  ids: IdFactory,
  defs: string[],
): string {
  const half = box / 2;
  switch (layer.type) {
  case "image": {
    const asset = assets.get(layer.assetId);
    if (!asset) {
      // A placeholder rather than nothing, so the agent can see that a layer is there and that its
      // artwork failed to load — silently dropping it would read as the layer having been deleted.
      return `<rect x="${-half}" y="${-half}" width="${box}" height="${box}" rx="${round(box * 0.12)}" `
        + `fill="#B39DDB" opacity="0.5"/>`
        + `<text x="0" y="0" font-size="${round(box * 0.1)}" fill="#311B92" text-anchor="middle" `
        + `dominant-baseline="middle" font-family="${FONT_STACKS.system}">artwork</text>`;
    }
    const href = `data:${asset.mimeType};base64,${Buffer.from(asset.bytes).toString("base64")}`;
    const fit = layer.contentMode === "fill" ? "xMidYMid slice" : "xMidYMid meet";
    return `<image x="${-half}" y="${-half}" width="${box}" height="${box}" `
      + `preserveAspectRatio="${fit}" href="${href}"/>`;
  }
  case "sequence": {
    const asset = assets.get(layer.assetId);
    if (!asset) {
      return `<rect x="${-half}" y="${-half}" width="${box}" height="${box}" rx="${round(box * 0.12)}" `
        + `fill="#B39DDB" opacity="0.5"/>`
        + `<text x="0" y="0" font-size="${round(box * 0.1)}" fill="#311B92" text-anchor="middle" `
        + `dominant-baseline="middle" font-family="${FONT_STACKS.system}">capture</text>`;
    }
    // One tile of the atlas, cropped with a nested viewport rather than by slicing pixels: librsvg
    // resolves the `viewBox` itself, so this costs no image processing at all. `sequenceFrameIndex`
    // is the same function the Swift renderer uses, so the frame the agent reviews here is the frame
    // the user will actually see.
    //
    // The sheet is drawn into a `columns` x `rows` *unit* grid rather than into its pixel
    // dimensions, so this needs no knowledge of how big the atlas actually is — `RenderAssets`
    // carries only bytes. That is exact because the encoder writes square tiles (it squares one
    // shared crop rect before scaling), so one grid cell is one tile with no distortion.
    const index = sequenceFrameIndex(layer, time);
    const column = index % layer.columns;
    const row = Math.floor(index / layer.columns);
    const href = `data:${asset.mimeType};base64,${Buffer.from(asset.bytes).toString("base64")}`;
    const fit = layer.contentMode === "fill" ? "xMidYMid slice" : "xMidYMid meet";
    return `<svg x="${round(-half)}" y="${round(-half)}" width="${round(box)}" height="${round(box)}" `
      + `viewBox="${column} ${row} 1 1" preserveAspectRatio="${fit}">`
      + `<image x="0" y="0" width="${layer.columns}" height="${layer.rows}" `
      + `preserveAspectRatio="none" href="${href}"/>`
      + `</svg>`;
  }
  case "text": {
    // Sized by character count rather than measured: librsvg has no text-fitting equivalent to
    // SwiftUI's `minimumScaleFactor`, so this keeps a long string inside the box approximately the
    // way the native renderer shrinks it.
    const longest = Math.max(...layer.text.split("\n").map((line) => line.length), 1);
    const size = Math.min(box * 0.34, (box * 1.7) / longest);
    const anchor = layer.alignment === "leading" ? "start" : layer.alignment === "trailing" ? "end" : "middle";
    const x = layer.alignment === "leading" ? -half : layer.alignment === "trailing" ? half : 0;
    const lines = layer.text.split("\n").slice(0, 3);
    const spans = lines
      .map((line, index) => `<tspan x="${round(x)}" dy="${index === 0 ? 0 : round(size * 1.1)}">${escapeText(line)}</tspan>`)
      .join("");
    return `<text x="${round(x)}" y="${round(-((lines.length - 1) * size * 1.1) / 2)}" `
      + `font-family="${FONT_STACKS[layer.font]}" font-weight="${FONT_WEIGHTS[layer.weight]}" `
      + `font-size="${round(size)}" fill="${paintValue(layer.paint, ids, defs)}" `
      + `text-anchor="${anchor}" dominant-baseline="central">${spans}</text>`;
  }
  case "shape": {
    const geometry = shapeGeometry(layer.shape, layer.cornerRadius);
    const fill = paintValue(layer.fill, ids, defs);
    const strokeAttrs = strokeAttributes(layer.stroke, box, ids, defs);
    // Trimming a fill would carve a partial blob out of the shape, so — as natively — the fill
    // fades with the trim window's coverage while the outline is what actually draws on.
    const coverage = Math.max(0, Math.min(1, state.trim.end - state.trim.start));
    const fillOpacity = layer.animation.trim.length > 0 ? ` fill-opacity="${round(coverage)}"` : "";
    if (geometry.kind === "ellipse") {
      return `<ellipse cx="0" cy="0" rx="${half}" ry="${half}" fill="${fill}"${fillOpacity}${strokeAttrs}/>`;
    }
    if (geometry.kind === "rect") {
      const radius = round(geometry.cornerRadius * box);
      return `<rect x="${-half}" y="${-half}" width="${box}" height="${box}" rx="${radius}" ry="${radius}" `
        + `fill="${fill}"${fillOpacity}${strokeAttrs}/>`;
    }
    // Unit-box path data, scaled into the fit box and centred.
    return `<g transform="translate(${-half},${-half}) scale(${round(box)})">`
      + `<path d="${geometry.d}" fill="${fill}"${fillOpacity} vector-effect="non-scaling-stroke"`
      + `${strokeAttributes(layer.stroke, box, ids, defs)}/></g>`;
  }
  case "svg": {
    if (layer.source.kind !== "inline") {
      const asset = assets.get(layer.source.assetId);
      if (!asset) return "";
      const markup = Buffer.from(asset.bytes).toString("utf8");
      return embedSvg(markup, box);
    }
    // Safe to nest: the markup passed `svgMarkupRejectionReason` on the way into the document —
    // no scripts, no remote references — which is the same argument the browser preview relies on.
    return embedSvg(layer.source.markup, box);
  }
  case "particle": {
    const colour = layer.paint.type === "solid" ? layer.paint.color : layer.paint.stops[0].color;
    const glyph = particleGlyph(layer.preset);
    const size = box * 0.09;
    return Array.from({ length: Math.min(layer.count, 48) }, (_, index) => {
      const point = particlePosition(layer.seed, index);
      return `<text x="${round(-half + point.x * box)}" y="${round(-half + point.y * box)}" `
        + `font-size="${round(size)}" fill="${colour}" text-anchor="middle" `
        + `dominant-baseline="middle">${glyph}</text>`;
    }).join("");
  }
  }
}

/**
 * Nests foreign SVG markup inside the layer's box.
 *
 * The outer `<svg>` element does the fitting: giving it a width, a height and a `viewBox` copied
 * from the source lets librsvg scale the artwork the same way `preserveAspectRatio` does for a
 * bitmap, without this having to parse the source's geometry.
 */
function embedSvg(markup: string, box: number): string {
  const half = box / 2;
  const viewBox = /viewBox\s*=\s*"([^"]+)"/i.exec(markup)?.[1] ?? "0 0 100 100";
  const inner = markup.replace(/^[\s\S]*?<svg[^>]*>/i, "").replace(/<\/svg>\s*$/i, "");
  return `<svg x="${-half}" y="${-half}" width="${box}" height="${box}" viewBox="${viewBox}" `
    + `preserveAspectRatio="xMidYMid meet">${inner}</svg>`;
}

/** SVG has no equivalent for several of the document's blend modes; those fall back to normal. */
const BLEND_MODES: Record<string, string> = {
  normal: "normal",
  multiply: "multiply",
  screen: "screen",
  overlay: "overlay",
  softLight: "soft-light",
  hardLight: "hard-light",
  difference: "difference",
  plusLighter: "plus-lighter",
};

function renderLayer(
  layer: StickerLayerV1,
  time: number,
  size: number,
  assets: RenderAssets,
  ids: IdFactory,
  defs: string[],
): string {
  if (layer.hidden) return "";
  const state = sampleLayerState(layer, time);
  if (state.opacity <= 0.001) return "";
  const box = size * LAYER_FIT;

  const body = layerBody(layer, state, time, box, assets, ids, defs);
  if (!body) return "";

  const attributes: string[] = [];
  const filterId = ids.make("f");
  const filter = effectFilter(state, box, filterId);
  if (filter) {
    defs.push(filter);
    attributes.push(`filter="url(#${filterId})"`);
  }
  const maskId = ids.make("m");
  const mask = wipeMask(state, maskId, box);
  if (mask) {
    defs.push(mask);
    attributes.push(`mask="url(#${maskId})"`);
  }
  if (state.opacity < 0.999) attributes.push(`opacity="${round(state.opacity)}"`);
  const blend = BLEND_MODES[layer.blendMode] ?? "normal";
  if (blend !== "normal") attributes.push(`style="mix-blend-mode:${blend}"`);

  // Translate to the layer's position, then rotate and scale about that point — the same order the
  // native renderer applies them in, which is what keeps a rotated layer's motion looking the same.
  const x = round(state.position.x * size);
  const y = round(state.position.y * size);
  const transform = `translate(${x},${y}) rotate(${round(state.rotationDegrees)}) `
    + `scale(${round(state.scale.x)},${round(state.scale.y)})`;

  const sheen = renderSheen(state, box, ids, defs);
  return `<g transform="${transform}" ${attributes.join(" ")}>${body}${sheen}</g>`;
}

/** The travelling highlight, as a band over the layer. Approximate: it is not clipped to the alpha. */
function renderSheen(state: LayerState, box: number, ids: IdFactory, defs: string[]): string {
  if (state.sheen.intensity <= 0.01) return "";
  const id = ids.make("sh");
  const radians = (state.sheen.angleDegrees * Math.PI) / 180;
  const extent = Math.abs(Math.cos(radians)) + Math.abs(Math.sin(radians));
  const dx = (Math.cos(radians) * extent) / 2;
  const dy = (Math.sin(radians) * extent) / 2;
  const half = state.sheen.width / 2;
  const stops = [
    ["#fff", state.sheen.position - half, 0],
    ["#fff", state.sheen.position, state.sheen.intensity],
    ["#fff", state.sheen.position + half, 0],
  ] as const;
  const body = stops
    .map(([color, location, opacity]) => [color, Math.min(Math.max(location, 0), 1), opacity] as const)
    .sort((a, b) => a[1] - b[1])
    .map(([color, location, opacity]) =>
      `<stop offset="${round(location)}" stop-color="${color}" stop-opacity="${round(opacity)}"/>`)
    .join("");
  defs.push(`<linearGradient id="${id}" x1="${round(0.5 - dx)}" y1="${round(0.5 - dy)}" `
    + `x2="${round(0.5 + dx)}" y2="${round(0.5 + dy)}">${body}</linearGradient>`);
  return `<rect x="${-box / 2}" y="${-box / 2}" width="${box}" height="${box}" fill="url(#${id})" `
    + `style="mix-blend-mode:plus-lighter"/>`;
}

function renderBackground(
  document: StickerDocument,
  size: number,
  assets: RenderAssets,
  ids: IdFactory,
  defs: string[],
): string {
  const background = document.background;
  if (background.type === "none") return "";
  if (background.type === "image") {
    const asset = assets.get(background.assetId);
    if (!asset) return "";
    const href = `data:${asset.mimeType};base64,${Buffer.from(asset.bytes).toString("base64")}`;
    const fit = background.contentMode === "fill" ? "xMidYMid slice" : "xMidYMid meet";
    return `<image x="0" y="0" width="${size}" height="${size}" preserveAspectRatio="${fit}" href="${href}"/>`;
  }
  const paint: PaintV2 = background.type === "solid"
    ? { type: "solid", color: background.color }
    : background.type === "linearGradient"
      ? { type: "linearGradient", stops: background.stops, angleDegrees: background.angleDegrees }
      : { type: "radialGradient", stops: background.stops, center: background.center, radius: background.radius };
  return `<rect x="0" y="0" width="${size}" height="${size}" fill="${paintValue(paint, ids, defs)}"/>`;
}

/** One frame of the document, as an SVG fragment positioned at the origin of a `size` box. */
export function frameFragment(
  document: StickerDocument,
  time: number,
  size: number,
  assets: RenderAssets,
  ids: IdFactory,
): { body: string; defs: string[] } {
  const defs: string[] = [];
  const background = renderBackground(document, size, assets, ids, defs);
  const layers = document.layers
    .map((layer) => renderLayer(layer, time, size, assets, ids, defs))
    .join("");
  return { body: background + layers, defs };
}

export { IdFactory };
