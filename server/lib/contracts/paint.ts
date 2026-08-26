import { z } from "zod";

/**
 * Paint, stroke, and SVG source contracts — the v2 vocabulary for "how is this drawn".
 *
 * These live in their own module for the same reason the keyframe schemas do: `contracts/sticker`
 * needs them, and so does `contracts/plan`, and neither may import the other.
 *
 * v1 expressed all of this as bare hex strings on each layer (`fill`, `stroke`, `color`). Making
 * paint its own type is what lets any fillable thing — a shape, a glyph, a stroke, an SVG subpath —
 * take a gradient without the renderer growing a special case per combination.
 */

export const HexColorSchema = z.string().regex(/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/);

export const GradientStopSchema = z.object({
  color: HexColorSchema,
  /** Position along the gradient's axis. */
  location: z.number().min(0).max(1),
}).strict();

export const NormalizedPointSchema = z.object({
  x: z.number().min(-1).max(2),
  y: z.number().min(-1).max(2),
}).strict();

/**
 * How a shape, glyph, or SVG subpath is filled.
 *
 * Mirrors `AnimatedPaint` in the Swift package exactly, including the `type` discriminator and the
 * two-stop minimum: a "gradient" with one stop is a solid colour written the hard way, and the
 * renderer would have to invent the missing end.
 */
export const PaintSchema: z.ZodType<PaintV2> = z.discriminatedUnion("type", [
  z.object({ type: z.literal("solid"), color: HexColorSchema }).strict(),
  z.object({
    type: z.literal("linearGradient"),
    stops: z.array(GradientStopSchema).min(2).max(8),
    angleDegrees: z.number().min(-360).max(360).default(0),
  }).strict(),
  z.object({
    type: z.literal("radialGradient"),
    stops: z.array(GradientStopSchema).min(2).max(8),
    center: NormalizedPointSchema.default({ x: 0.5, y: 0.5 }),
    radius: z.number().min(0.01).max(4).default(0.5),
  }).strict(),
]);

export type PaintV2 =
  | { type: "solid"; color: string }
  | { type: "linearGradient"; stops: Array<{ color: string; location: number }>; angleDegrees: number }
  | {
    type: "radialGradient";
    stops: Array<{ color: string; location: number }>;
    center: { x: number; y: number };
    radius: number;
  };

/**
 * An outline.
 *
 * `width` is a fraction of the layer's fit box — not of the canvas, and not in points. That is what
 * keeps a stroke's visual weight the same whether the document renders at 64pt or 2048px, and what
 * makes an SVG layer's stroke override mean the same thing as a shape layer's regardless of the
 * artwork's own viewBox units.
 */
export const StrokeSchema = z.object({
  paint: PaintSchema,
  width: z.number().min(0).max(0.5).default(0.01),
  lineCap: z.enum(["butt", "round", "square"]).default("round"),
  lineJoin: z.enum(["miter", "round", "bevel"]).default("round"),
  dash: z.array(z.number().min(0).max(2)).max(8).default([]),
}).strict();

/** The primitive a shape layer draws, including the parameterised and free-form cases. */
export const ShapeKindSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("circle") }).strict(),
  z.object({ kind: z.literal("roundedRectangle") }).strict(),
  z.object({ kind: z.literal("capsule") }).strict(),
  z.object({ kind: z.literal("triangle") }).strict(),
  z.object({ kind: z.literal("heart") }).strict(),
  z.object({ kind: z.literal("burst") }).strict(),
  z.object({
    kind: z.literal("star"),
    points: z.number().int().min(3).max(24).default(5),
    innerRatio: z.number().min(0.05).max(1).default(0.42),
  }).strict(),
  z.object({ kind: z.literal("polygon"), sides: z.number().int().min(3).max(24).default(6) }).strict(),
  /** SVG path data, so a caller with a path does not need a whole SVG document to draw it. */
  z.object({ kind: z.literal("path"), d: z.string().min(1).max(20_000) }).strict(),
]);

/** The largest inline SVG a single layer may carry. */
export const MAX_SVG_MARKUP_BYTES = 200_000;

const BANNED_SVG_SUBSTRINGS = ["<script", "<foreignobject", "<iframe", "javascript:"] as const;
const REFERENCING_ATTRIBUTES = ["href", "src", "url("] as const;

/**
 * Whether any occurrence of `attribute` is followed by a value that would be fetched.
 *
 * The value is read directly rather than scanning a window around the attribute, because a base64
 * data URI legitimately contains `/` characters and would trip a windowed check. A port of
 * `AnimatedSVGSource.referencesRemoteURL` in the Swift package; the two must agree, since a
 * document rejected by one and accepted by the other is a document that renders in some places and
 * not others.
 */
function referencesRemoteURL(attribute: string, lowered: string): boolean {
  let index = lowered.indexOf(attribute);
  while (index !== -1) {
    let cursor = index + attribute.length;
    while (cursor < lowered.length && "=\"' \t\n".includes(lowered[cursor])) cursor += 1;
    const value = lowered.slice(cursor, cursor + 8);
    if (value.startsWith("http://") || value.startsWith("https://") || value.startsWith("//")) return true;
    index = lowered.indexOf(attribute, index + attribute.length);
  }
  return false;
}

/**
 * Rejects markup that would turn a document into a fetch or an execution.
 *
 * This is a real security boundary, not tidiness. A document is stored, replayed, and re-rendered
 * by the web preview, and that one runs the markup in a browser where a `<script>` is live and a
 * remote `href` leaks a request to whoever authored the artwork. `xmlns` is deliberately not
 * treated as a reference: it is `http://www.w3.org/…` in essentially every real SVG and is a
 * namespace identifier that is never fetched. Data URIs stay allowed, being self-contained.
 */
export function svgMarkupRejectionReason(markup: string): string | null {
  if (markup.length === 0) return "The artwork is empty";
  if (Buffer.byteLength(markup, "utf8") > MAX_SVG_MARKUP_BYTES) {
    return `The artwork exceeds ${MAX_SVG_MARKUP_BYTES} bytes`;
  }
  const lowered = markup.toLowerCase();
  for (const banned of BANNED_SVG_SUBSTRINGS) {
    if (lowered.includes(banned)) return `The artwork contains ${banned}`;
  }
  for (const attribute of REFERENCING_ATTRIBUTES) {
    if (referencesRemoteURL(attribute, lowered)) return "The artwork references a remote URL";
  }
  return null;
}

export const SVGSourceSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("inline"),
    markup: z.string(),
  }).strict().superRefine((value, context) => {
    const reason = svgMarkupRejectionReason(value.markup);
    if (reason) context.addIssue({ code: "custom", message: reason, path: ["markup"] });
  }),
  z.object({ kind: z.literal("asset"), assetId: z.string().uuid() }).strict(),
]);

export type StrokeV2 = z.infer<typeof StrokeSchema>;
export type ShapeKindV2 = z.infer<typeof ShapeKindSchema>;
export type SVGSourceV2 = z.infer<typeof SVGSourceSchema>;
export type GradientStopV2 = z.infer<typeof GradientStopSchema>;
