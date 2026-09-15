import { z } from "zod";

/**
 * The parts of a sprite layer that are not the layer base: its clips, its expression sheet, and the
 * rules that tie them together. `SpriteLayerV1Schema` in `sticker.ts` is the layer base extended
 * with `SpriteLayerFieldsV1`; everything here is written against the structural shapes so the
 * helpers can be shared with a resolved document, a plan, and the tests without importing the
 * whole document contract.
 *
 * A sprite is the RxPet model: one body atlas per motion (a clip), a face anchor registered in
 * every frame, and a strip of face expressions composited into that anchor at draw time. Mood and
 * pose are therefore independent choices — three faces and four clips cost seven sheets, never
 * twelve — and `speed` is free because the frame index is a function of document time.
 */

const AssetIdSchema = z.string().uuid();
const IdSchema = z.string().min(1).max(64).regex(/^[A-Za-z0-9_-]+$/);

/**
 * One frame of a clip: how long it holds, and where the face slot sits in it.
 *
 * `faceX`/`faceY` are the slot's centre as fractions of the cell, and `faceSize` is its width as a
 * fraction of the cell's width — the numbers `lib/render/sprite-registration.ts` reads off the
 * placeholder the image model was asked to draw. Every expression tile is drawn into that slot, so
 * the face follows the body from frame to frame without the body ever being redrawn.
 */
export const SpriteFrameV1Schema = z.object({
  duration: z.number().min(0.05).max(10),
  faceX: z.number().min(0).max(1),
  faceY: z.number().min(0).max(1),
  faceSize: z.number().min(0.02).max(1),
}).strict();

/**
 * One motion of a character: a short sheet of body frames with per-frame timing.
 *
 * Timing is per frame rather than a rate because that is what makes a loop read as alive: an idle
 * clip holds its resting frame for seconds and blinks for a fifth of one. `spriteFrameIndex` walks
 * the durations modulo their sum, so a clip loops on its own clock regardless of the document's
 * `durationSeconds`.
 */
export const SpriteClipV1Schema = z.object({
  id: IdSchema,
  /** The clip's sheet: `rows` x `columns` cells, row-major, one frame each. */
  assetId: AssetIdSchema,
  columns: z.number().int().min(1).max(8),
  rows: z.number().int().min(1).max(8),
  frames: z.array(SpriteFrameV1Schema).min(1).max(8),
}).strict().superRefine((clip, context) => {
  if (clip.frames.length > clip.rows * clip.columns) {
    context.addIssue({
      code: "custom",
      message: `Sprite clip ${clip.id} declares ${clip.frames.length} frames but its ${clip.rows}x${clip.columns} grid holds only ${clip.rows * clip.columns}`,
    });
  }
});

/** One face on the expression sheet, as its opaque bounds normalized to the whole sheet. */
export const SpriteExpressionTileV1Schema = z.object({
  id: IdSchema,
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  width: z.number().min(0.001).max(1),
  height: z.number().min(0.001).max(1),
}).strict();

export const SpriteExpressionsV1Schema = z.object({
  /** The expression sheet: a grid of face plates, one per mood, on transparent. */
  assetId: AssetIdSchema,
  columns: z.number().int().min(1).max(8),
  rows: z.number().int().min(1).max(8),
  tiles: z.array(SpriteExpressionTileV1Schema).min(1).max(8),
}).strict().superRefine((sheet, context) => {
  if (sheet.tiles.length > sheet.rows * sheet.columns) {
    context.addIssue({
      code: "custom",
      message: `Expression sheet declares ${sheet.tiles.length} tiles but its ${sheet.rows}x${sheet.columns} grid holds only ${sheet.rows * sheet.columns}`,
    });
  }
});

/**
 * The sprite-specific fields of the layer. `posterAssetId` is required: the server always builds a
 * sprite, and the poster is what every consumer that cannot composite draws in its place — older
 * clients, thumbnails, the marketplace.
 */
export const SpriteLayerFieldsV1 = {
  type: z.literal("sprite"),
  clips: z.array(SpriteClipV1Schema).min(1).max(8),
  expressions: SpriteExpressionsV1Schema,
  /** The clip playing when no control says otherwise. */
  clipId: IdSchema,
  /** The face shown when no control says otherwise. */
  expressionId: IdSchema,
  contentMode: z.enum(["fit", "fill"]).default("fit"),
  /** The default clip's first frame with the default face composited, fitted to a 1024 square. */
  posterAssetId: AssetIdSchema,
};

export type SpriteClipV1 = z.infer<typeof SpriteClipV1Schema>;
export type SpriteFrameV1 = z.infer<typeof SpriteFrameV1Schema>;
export type SpriteExpressionTileV1 = z.infer<typeof SpriteExpressionTileV1Schema>;

/** The structural shape every helper below works against; the layer schema and the Swift model both satisfy it. */
export type SpriteLike = {
  id: string;
  clips: SpriteClipV1[];
  expressions: z.infer<typeof SpriteExpressionsV1Schema>;
  clipId: string;
  expressionId: string;
};

/** What is wrong with a sprite layer on its own: repeated ids, or a default that names nothing. */
export function spriteLayerIssues(layer: SpriteLike): string[] {
  const issues: string[] = [];
  const clipIds = layer.clips.map((clip) => clip.id);
  const tileIds = layer.expressions.tiles.map((tile) => tile.id);
  if (new Set(clipIds).size !== clipIds.length) issues.push(`Sprite layer ${layer.id} repeats a clip id`);
  if (new Set(tileIds).size !== tileIds.length) issues.push(`Sprite layer ${layer.id} repeats an expression id`);
  if (!clipIds.includes(layer.clipId)) issues.push(`Sprite layer ${layer.id} defaults to unknown clip ${layer.clipId}`);
  if (!tileIds.includes(layer.expressionId)) issues.push(`Sprite layer ${layer.id} defaults to unknown expression ${layer.expressionId}`);
  return issues;
}

/**
 * What is wrong with a sprite in a given document: a still has no timeline to walk its clips on,
 * and a frame shorter than one render tick would never be shown, so the blink the planner timed
 * would silently vanish.
 */
export function spriteDocumentIssues(layer: SpriteLike, document: { kind: "static" | "animated"; fps: number }): string[] {
  if (document.kind === "static") {
    return [`Sprite layer ${layer.id} is a character with clips and expressions, which needs an animated document.`];
  }
  const shortest = Math.min(...layer.clips.flatMap((clip) => clip.frames.map((frame) => frame.duration)));
  if (1 / document.fps > shortest + 1e-9) {
    return [`Sprite layer ${layer.id} has a ${shortest}s frame but the document renders at ${document.fps} fps, `
      + `which cannot show it. Raise the document's fps to at least ${Math.ceil(1 / shortest)}.`];
  }
  return [];
}

/** The clip a sprite layer is currently set to play. The schema guarantees it exists. */
export function spriteClip<T extends SpriteLike>(layer: T): T["clips"][number] {
  return layer.clips.find((clip) => clip.id === layer.clipId) ?? layer.clips[0];
}

/** The expression tile a sprite layer is currently set to show. The schema guarantees it exists. */
export function spriteExpressionTile(layer: SpriteLike): SpriteExpressionTileV1 {
  return layer.expressions.tiles.find((tile) => tile.id === layer.expressionId) ?? layer.expressions.tiles[0];
}

/** Applies a variant's clip and expression selection to a sprite, refusing ids the sprite does not declare. */
export function selectSpriteState(layer: SpriteLike, patch: { clip?: string; expression?: string }): void {
  if (patch.clip !== undefined) {
    if (!layer.clips.some((clip) => clip.id === patch.clip)) throw new Error(`Sprite layer ${layer.id} has no clip ${patch.clip}`);
    layer.clipId = patch.clip;
  }
  if (patch.expression !== undefined) {
    if (!layer.expressions.tiles.some((tile) => tile.id === patch.expression)) throw new Error(`Sprite layer ${layer.id} has no expression ${patch.expression}`);
    layer.expressionId = patch.expression;
  }
}
