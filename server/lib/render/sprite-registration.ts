import sharp from "sharp";
import { SpriteSheetValidationError } from "./sprite-atlas";

/**
 * Reading a sprite character's sheets back into numbers, and drawing them back together.
 *
 * A sprite is two kinds of sheet — body clips and an expression strip — that only become a
 * character when a face is drawn into each body frame at the right spot. Nothing about that spot
 * can be trusted to a prompt, so the image model is asked to leave a flat magenta oval where the
 * face goes, and this module measures it: centre and width per cell, then paints the placeholder
 * out with the colour around it so the stored sheet is a clean body with a blank face. That is the
 * whole reason the placeholder is a colour no character is drawn in.
 *
 * `compositeSpriteFrame` is the server's one implementation of the draw itself. `SpriteFrameCache`
 * in `AnimatedView` is the other, and the two agree on `FACE_OVERCOVER`, the anchor, and the fit
 * rule, which is what a pixel test on each side pins.
 */

/** Where the face slot sits in one body frame, as fractions of the cell. See `SpriteFrameV1Schema`. */
export type FaceSlot = { faceX: number; faceY: number; faceSize: number };

/** A sheet's grid and how many of its row-major cells are in use. */
export type SheetGrid = { columns: number; rows: number; frameCount: number };

/** One face on the expression sheet, as its opaque bounds normalized to the sheet. */
export type ExpressionTile = { x: number; y: number; width: number; height: number };

/**
 * How much wider than the registered slot a face is drawn.
 *
 * The placeholder's edge is antialiased and the inpaint feathers a pixel or two past it, so a face
 * drawn at exactly the measured width leaves a hairline of body colour showing round it. A little
 * overcover hides that; the number is shared with the Swift renderer.
 */
export const FACE_OVERCOVER = 1.08;

/**
 * Whether one pixel is the face placeholder.
 *
 * Pure magenta with generous tolerance: the model shades and antialiases the oval it was told to
 * keep flat, so red and blue only have to dominate green clearly rather than sit at 255 and 0.
 * Anything a character is plausibly drawn in — pink cheeks, purple fur — has far more green in it.
 */
function isPlaceholder(r: number, g: number, b: number, a: number): boolean {
  return a > 200 && r > 150 && b > 150 && g < 0.45 * Math.min(r, b);
}

type Raw = { data: Buffer; width: number; height: number; channels: number };

async function rawPixels(bytes: Uint8Array): Promise<Raw> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data, width: info.width, height: info.height, channels: info.channels };
}

function cellSize(raw: Raw, grid: SheetGrid): { cellWidth: number; cellHeight: number } {
  const cellWidth = Math.floor(raw.width / grid.columns);
  const cellHeight = Math.floor(raw.height / grid.rows);
  if (cellWidth < 8 || cellHeight < 8) throw new Error(`Sheet is ${raw.width}x${raw.height}, too small for a ${grid.columns}x${grid.rows} grid`);
  return { cellWidth, cellHeight };
}

/** A box dilation by `radius` (Chebyshev), separable so a 7px ring on a 1024² sheet stays cheap. */
function dilate(mask: Uint8Array, width: number, height: number, radius: number): Uint8Array {
  const horizontal = new Uint8Array(width * height);
  for (let y = 0; y < height; y += 1) {
    const row = y * width;
    for (let x = 0; x < width; x += 1) {
      if (!mask[row + x]) continue;
      for (let dx = -radius; dx <= radius; dx += 1) {
        const nx = x + dx;
        if (nx >= 0 && nx < width) horizontal[row + nx] = 1;
      }
    }
  }
  const result = new Uint8Array(width * height);
  for (let y = 0; y < height; y += 1) {
    const row = y * width;
    for (let x = 0; x < width; x += 1) {
      if (!horizontal[row + x]) continue;
      for (let dy = -radius; dy <= radius; dy += 1) {
        const ny = y + dy;
        if (ny >= 0 && ny < height) result[ny * width + x] = 1;
      }
    }
  }
  return result;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
}

/**
 * Finds the face placeholder in every cell of a clip sheet and paints it out.
 *
 * Fails, with a message naming the frame, whenever a cell's placeholder is missing, scattered,
 * oversized, or touching the cell edge: each of those means the model did not draw the sheet it was
 * asked for, and the build's retry path buys another rather than shipping a face nothing can be
 * drawn into. Returns the cleaned sheet and one slot per frame.
 */
export async function registerFaceSlots(
  bytes: Uint8Array,
  grid: SheetGrid,
): Promise<{ bytes: Uint8Array; frames: FaceSlot[] }> {
  const raw = await rawPixels(bytes);
  const { data, width, height, channels } = raw;
  const { cellWidth, cellHeight } = cellSize(raw, grid);
  const mask = new Uint8Array(width * height);
  const frames: FaceSlot[] = [];

  for (let frame = 0; frame < grid.frameCount; frame += 1) {
    const ox = (frame % grid.columns) * cellWidth;
    const oy = Math.floor(frame / grid.columns) * cellHeight;
    let count = 0, sumX = 0, sumY = 0;
    let minX = cellWidth, minY = cellHeight, maxX = -1, maxY = -1;
    for (let y = 0; y < cellHeight; y += 1) {
      for (let x = 0; x < cellWidth; x += 1) {
        const offset = ((oy + y) * width + ox + x) * channels;
        if (!isPlaceholder(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])) continue;
        mask[(oy + y) * width + ox + x] = 1;
        count += 1; sumX += x; sumY += y;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
    const area = cellWidth * cellHeight;
    if (count < area * 0.002) throw new SpriteSheetValidationError("face-placeholder", `Sprite frame ${frame + 1} has no face placeholder: draw a flat magenta oval where the face goes`);
    if (count > area * 0.3) throw new SpriteSheetValidationError("face-placeholder", `Sprite frame ${frame + 1} has a face placeholder covering most of the cell`);
    const boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1;
    if (boxWidth * boxHeight > count * 4) throw new SpriteSheetValidationError("face-placeholder", `Sprite frame ${frame + 1} has magenta scattered outside the face placeholder`);
    if (minX <= 0 || minY <= 0 || maxX >= cellWidth - 1 || maxY >= cellHeight - 1) {
      throw new SpriteSheetValidationError("clipped", `Sprite frame ${frame + 1} has its face placeholder clipped at the cell edge`);
    }
    frames.push({
      faceX: (sumX / count + 0.5) / cellWidth,
      faceY: (sumY / count + 0.5) / cellHeight,
      faceSize: boxWidth / cellWidth,
    });
  }

  // Inpaint: the placeholder grown by two pixels, so its antialiased rim goes too, filled with the
  // median colour of a ring just outside it — fur, skin, or shell, whatever the face sits on.
  const fill = dilate(mask, width, height, 2);
  const ring = dilate(fill, width, height, 7);
  const output = Buffer.from(data);
  for (let frame = 0; frame < grid.frameCount; frame += 1) {
    const ox = (frame % grid.columns) * cellWidth;
    const oy = Math.floor(frame / grid.columns) * cellHeight;
    const reds: number[] = [], greens: number[] = [], blues: number[] = [];
    for (let y = 0; y < cellHeight; y += 1) {
      for (let x = 0; x < cellWidth; x += 1) {
        const index = (oy + y) * width + ox + x;
        if (!ring[index] || fill[index]) continue;
        const offset = index * channels;
        if (data[offset + 3] <= 200) continue;
        reds.push(data[offset]); greens.push(data[offset + 1]); blues.push(data[offset + 2]);
      }
    }
    const colour = reds.length ? [median(reds), median(greens), median(blues)] : [128, 128, 128];
    for (let y = 0; y < cellHeight; y += 1) {
      for (let x = 0; x < cellWidth; x += 1) {
        const index = (oy + y) * width + ox + x;
        if (!fill[index]) continue;
        const offset = index * channels;
        output[offset] = colour[0]; output[offset + 1] = colour[1]; output[offset + 2] = colour[2]; output[offset + 3] = 255;
      }
    }
  }
  const png = await sharp(output, { raw: { width, height, channels: channels as 4 } }).png().toBuffer();
  return { bytes: new Uint8Array(png), frames };
}

/**
 * Measures every face on an expression sheet as its opaque bounds, normalized to the sheet.
 *
 * A tile is drawn scaled to the slot's width, so its bounds have to be tight or the face lands
 * smaller than the slot. Fails on an empty cell or one whose drawing runs into the cell boundary.
 */
export async function registerExpressionTiles(bytes: Uint8Array, grid: SheetGrid): Promise<ExpressionTile[]> {
  const raw = await rawPixels(bytes);
  const { data, width, height, channels } = raw;
  const { cellWidth, cellHeight } = cellSize(raw, grid);
  const tiles: ExpressionTile[] = [];
  for (let frame = 0; frame < grid.frameCount; frame += 1) {
    const ox = (frame % grid.columns) * cellWidth;
    const oy = Math.floor(frame / grid.columns) * cellHeight;
    let count = 0;
    let minX = cellWidth, minY = cellHeight, maxX = -1, maxY = -1;
    for (let y = 0; y < cellHeight; y += 1) {
      for (let x = 0; x < cellWidth; x += 1) {
        if (data[((oy + y) * width + ox + x) * channels + 3] <= 24) continue;
        count += 1;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
    if (count < cellWidth * cellHeight * 0.005) throw new SpriteSheetValidationError("empty", `Expression ${frame + 1} is empty`);
    if (minX <= 0 || minY <= 0 || maxX >= cellWidth - 1 || maxY >= cellHeight - 1) {
      throw new SpriteSheetValidationError("clipped", `Expression ${frame + 1} is clipped at its cell boundary`);
    }
    const pad = 2;
    const left = Math.max(0, minX - pad), top = Math.max(0, minY - pad);
    const right = Math.min(cellWidth - 1, maxX + pad), bottom = Math.min(cellHeight - 1, maxY + pad);
    tiles.push({
      x: (ox + left) / width,
      y: (oy + top) / height,
      width: (right - left + 1) / width,
      height: (bottom - top + 1) / height,
    });
  }
  return tiles;
}

/**
 * One body frame with one face drawn into its slot, as a transparent PNG the size of the cell.
 *
 * The face is scaled so its width is `faceSize * cellWidth * FACE_OVERCOVER`, keeps its own aspect,
 * and is centred on the slot; whatever falls outside the cell is cropped rather than refused, since
 * a face near a cell's edge is the model's framing, not an error. `edge`, when given, shrinks the
 * result to fit a review tile.
 */
export async function compositeSpriteFrame(input: {
  atlas: Uint8Array;
  clip: { columns: number; rows: number; frames: readonly FaceSlot[] };
  index: number;
  sheet: Uint8Array;
  tile: ExpressionTile;
  edge?: number;
}): Promise<Uint8Array> {
  const { clip, index, tile } = input;
  const frame = clip.frames[index];
  if (!frame) throw new Error(`Clip has no frame ${index}`);
  const atlasMeta = await sharp(input.atlas).metadata();
  const cellWidth = Math.floor((atlasMeta.width ?? 0) / clip.columns);
  const cellHeight = Math.floor((atlasMeta.height ?? 0) / clip.rows);
  if (cellWidth < 1 || cellHeight < 1) throw new Error(`Clip sheet is ${atlasMeta.width}x${atlasMeta.height}`);
  const cell = await sharp(input.atlas).ensureAlpha().extract({
    left: (index % clip.columns) * cellWidth,
    top: Math.floor(index / clip.columns) * cellHeight,
    width: cellWidth,
    height: cellHeight,
  }).png().toBuffer();

  const sheetMeta = await sharp(input.sheet).metadata();
  const sheetWidth = sheetMeta.width ?? 0, sheetHeight = sheetMeta.height ?? 0;
  const tileLeft = Math.max(0, Math.round(tile.x * sheetWidth));
  const tileTop = Math.max(0, Math.round(tile.y * sheetHeight));
  const tileWidth = Math.max(1, Math.min(sheetWidth - tileLeft, Math.round(tile.width * sheetWidth)));
  const tileHeight = Math.max(1, Math.min(sheetHeight - tileTop, Math.round(tile.height * sheetHeight)));

  const faceWidth = Math.max(1, Math.round(frame.faceSize * cellWidth * FACE_OVERCOVER));
  const faceHeight = Math.max(1, Math.round(faceWidth * tileHeight / tileWidth));
  const face = await sharp(input.sheet).ensureAlpha()
    .extract({ left: tileLeft, top: tileTop, width: tileWidth, height: tileHeight })
    .resize(faceWidth, faceHeight, { fit: "fill" })
    .png().toBuffer();

  // sharp refuses an overlay that hangs off its base, so crop the face to the part inside the cell.
  const left = Math.round(frame.faceX * cellWidth - faceWidth / 2);
  const top = Math.round(frame.faceY * cellHeight - faceHeight / 2);
  const visibleLeft = Math.max(0, left), visibleTop = Math.max(0, top);
  const visibleRight = Math.min(cellWidth, left + faceWidth), visibleBottom = Math.min(cellHeight, top + faceHeight);
  let composed = sharp(cell);
  if (visibleRight > visibleLeft && visibleBottom > visibleTop) {
    const cropped = await sharp(face).extract({
      left: visibleLeft - left, top: visibleTop - top,
      width: visibleRight - visibleLeft, height: visibleBottom - visibleTop,
    }).png().toBuffer();
    composed = composed.composite([{ input: cropped, left: visibleLeft, top: visibleTop }]);
  }
  if (input.edge) {
    composed = sharp(await composed.png().toBuffer()).resize(input.edge, input.edge, { fit: "inside", withoutEnlargement: true });
  }
  return new Uint8Array(await composed.png({ compressionLevel: 9 }).toBuffer());
}
