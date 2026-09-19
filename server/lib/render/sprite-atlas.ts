import sharp from "sharp";

/** Invalid generated artwork can be redrawn; decoding, storage and provider errors cannot. */
export class SpriteSheetValidationError extends Error {
  constructor(readonly reason: "clipped" | "empty" | "face-placeholder", message: string) {
    super(message);
    this.name = "SpriteSheetValidationError";
  }
}

type Grid = { columns: number; rows: number; frameCount: number };

/** Alpha at or below this is the transparency the sheet is cut out of, not artwork. */
const VISIBLE_ALPHA = 24;

/**
 * The fraction of a cell each side may not reach.
 *
 * `sheetInstruction` asks the model for 15% transparent margins and forbids touching a boundary at
 * all, so gating at 5% is three times looser than what was requested: a sheet that obeys the prompt
 * clears this comfortably, and only real overshoot trips it.
 */
const CELL_SAFE_MARGIN = 0.05;

/**
 * A blob smaller than this fraction of a cell is alpha noise, not a drawing.
 *
 * Generated sheets carry stray near-opaque specks — a few pixels of anti-aliasing left on the rim,
 * a dot in a cell nothing was drawn in. They are invisible at display size, but they sit exactly
 * where the checks below look, so counting them as artwork condemns an intact sheet to a redraw.
 */
const SPECK_CELL_AREA = 0.0002;

/**
 * Alpha padding catches sheets whose frames bleed across cells before they can become variants.
 *
 * Containment is measured as each cell's alpha **bounding box**, not as a count of pixels sitting on
 * the cell's one-pixel border ring. The ring is what the earlier gate counted, and it let the
 * reported artifact through: a wing that overshoots its cell crosses the ring over only a short span
 * — far below the old `(width + height) * 0.1` threshold — while the part that landed next door is
 * then cut out as a sliver of its neighbour's frame. A bounding box notices the same wing however
 * few pixels wide it is.
 *
 * Throwing `"clipped"` is deliberate: `prepareSheet` answers that reason by trying
 * `padGeneratedAtlas`, which re-cuts the grid around the drawings themselves and rescales — so a
 * sheet whose drawings are intact but drifted is repaired for free, and only an unrecoverable one
 * is redrawn.
 *
 * There is no separate gutter scan. Artwork can only reach a neighbouring cell by passing through
 * the edge of some cell, and every cell is checked here: a used one by its bounding box, an unused
 * one by being empty at all.
 */
export async function validateGeneratedAtlas(bytes: Uint8Array, grid: Grid): Promise<void> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const width = Math.floor(info.width / grid.columns), height = Math.floor(info.height / grid.rows);
  const opaque = (x: number, y: number) => data[(y * info.width + x) * info.channels + info.channels - 1] > VISIBLE_ALPHA;
  const marginX = Math.max(1, Math.round(width * CELL_SAFE_MARGIN));
  const marginY = Math.max(1, Math.round(height * CELL_SAFE_MARGIN));

  for (let frame = 0; frame < grid.columns * grid.rows; frame++) {
    const ox = (frame % grid.columns) * width, oy = Math.floor(frame / grid.columns) * height;
    let visible = 0, left = width, right = -1, top = height, bottom = -1;
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      if (!opaque(ox + x, oy + y)) continue;
      visible++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
    // Cells past the frame count are supposed to be untouched, so anything in one is either a
    // drawing that spilled out of its neighbour or a frame the model was not asked for.
    if (frame >= grid.frameCount) {
      if (visible > width * height * 0.0005) {
        throw new SpriteSheetValidationError("clipped", `Generated sheet has artwork in unused cell ${frame + 1}`);
      }
      continue;
    }
    if (visible < width * height * 0.005) throw new SpriteSheetValidationError("empty", `Generated pose frame ${frame + 1} is empty`);
    if (left < marginX || top < marginY || right >= width - marginX || bottom >= height - marginY) {
      throw new SpriteSheetValidationError("clipped", `Generated pose frame ${frame + 1} is clipped at its cell boundary`);
    }
  }
}

/** One connected run of visible pixels: where it is, how big, and how it straddles the grid. */
type Blob = {
  area: number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  /** Visible pixels per nominal cell index, which is how a blob's owning cell is decided. */
  cellArea: Map<number, number>;
};

/**
 * Labels every 8-connected run of visible pixels.
 *
 * Eight-connected rather than four: a drawing's diagonal hairline — a whisker, an antenna, the
 * corner where two strokes meet — is one object to the eye, and splitting it into a chain of
 * specks would hand each piece to whichever cell it happened to land in.
 */
function labelBlobs(
  data: Buffer,
  info: { width: number; height: number; channels: number },
  cell: { width: number; height: number; columns: number; rows: number },
): { labels: Int32Array; blobs: Blob[] } {
  const { width, height, channels } = info;
  const labels = new Int32Array(width * height).fill(-1);
  const stack = new Int32Array(width * height);
  const blobs: Blob[] = [];
  const visible = (index: number) => data[index * channels + channels - 1] > VISIBLE_ALPHA;

  for (let start = 0; start < width * height; start++) {
    if (labels[start] !== -1 || !visible(start)) continue;
    const id = blobs.length;
    const blob: Blob = { area: 0, left: width, right: -1, top: height, bottom: -1, cellArea: new Map() };
    blobs.push(blob);
    labels[start] = id;
    let depth = 0;
    stack[depth++] = start;
    while (depth > 0) {
      const index = stack[--depth];
      const x = index % width, y = (index - x) / width;
      blob.area++;
      if (x < blob.left) blob.left = x;
      if (x > blob.right) blob.right = x;
      if (y < blob.top) blob.top = y;
      if (y > blob.bottom) blob.bottom = y;
      // The last column and row of the sheet can fall outside the nominal grid when the sheet's
      // size does not divide evenly; those pixels belong to the edge cell.
      const column = Math.min(cell.columns - 1, Math.floor(x / cell.width));
      const row = Math.min(cell.rows - 1, Math.floor(y / cell.height));
      const owner = row * cell.columns + column;
      blob.cellArea.set(owner, (blob.cellArea.get(owner) ?? 0) + 1);
      for (let dy = -1; dy <= 1; dy++) {
        const ny = y + dy;
        if (ny < 0 || ny >= height) continue;
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          if (nx < 0 || nx >= width) continue;
          const neighbour = ny * width + nx;
          if (labels[neighbour] !== -1 || !visible(neighbour)) continue;
          labels[neighbour] = id;
          stack[depth++] = neighbour;
        }
      }
    }
  }
  return { labels, blobs };
}

/**
 * Recover intact drawings that stray across the nominal grid.
 *
 * The grid is re-cut around the drawings themselves rather than along clear rows and columns of
 * transparency. A straight seam only exists when every frame in a row stops short of the same line,
 * and the sheets that need repairing are exactly the ones where one pose leans past it — so seam
 * cutting refused the common case and spent a paid redraw on artwork that was entirely intact.
 * Connected runs of pixels have no such requirement: a drawing that drifts into its neighbour's
 * cell is still one blob, still whole, and still belongs to whichever cell holds most of it.
 *
 * What cannot be recovered is a drawing with pixels genuinely missing, or two drawings fused into
 * one blob — there is no seam to cut and nothing here can say which pixels belong to which frame.
 * Both throw, which sends the sheet back to be redrawn. A single scale and the original nominal
 * cell anchors preserve motion between frames.
 */
export async function padGeneratedAtlas(bytes: Uint8Array, grid: Grid): Promise<Uint8Array> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const width = Math.floor(info.width / grid.columns), height = Math.floor(info.height / grid.rows);
  const { labels, blobs } = labelBlobs(data, info, { width, height, columns: grid.columns, rows: grid.rows });
  const kept = blobs.map((blob) => blob.area > width * height * SPECK_CELL_AREA);
  const keptAt = (x: number, y: number) => {
    const label = labels[y * info.width + x];
    return label >= 0 && kept[label];
  };

  // A drawing the sheet itself cut off is missing pixels that no rescale can restore. A speck
  // resting on the rim is not that; a flat run along it is where a silhouette was sliced.
  const rimRun = Math.max(4, Math.round(Math.min(width, height) * 0.02));
  const longestRun = (length: number, at: (position: number) => boolean): number => {
    let longest = 0, run = 0;
    for (let position = 0; position < length; position++) {
      run = at(position) ? run + 1 : 0;
      if (run > longest) longest = run;
    }
    return longest;
  };
  if (longestRun(info.width, (x) => keptAt(x, 0)) > rimRun
    || longestRun(info.width, (x) => keptAt(x, info.height - 1)) > rimRun
    || longestRun(info.height, (y) => keptAt(0, y)) > rimRun
    || longestRun(info.height, (y) => keptAt(info.width - 1, y)) > rimRun) {
    throw new Error("Cannot recover a sprite sheet clipped at its outer edge");
  }

  // Each drawing goes to the cell holding most of it, and a cell may hold several: a character and
  // the spark it throws are two blobs of one frame.
  const owners = new Int32Array(blobs.length).fill(-1);
  const cells = new Map<number, { left: number; right: number; top: number; bottom: number; area: number }>();
  for (let id = 0; id < blobs.length; id++) {
    if (!kept[id]) continue;
    const blob = blobs[id];
    let owner = -1, ownerArea = 0;
    for (const [cell, area] of blob.cellArea) {
      if (area > ownerArea) { owner = cell; ownerArea = area; }
    }
    if (owner >= grid.frameCount) throw new Error("Cannot recover a sprite sheet with artwork in unused cells");
    owners[id] = owner;
    const bounds = cells.get(owner);
    cells.set(owner, bounds
      ? {
        left: Math.min(bounds.left, blob.left), right: Math.max(bounds.right, blob.right),
        top: Math.min(bounds.top, blob.top), bottom: Math.max(bounds.bottom, blob.bottom),
        area: bounds.area + blob.area,
      }
      : { left: blob.left, right: blob.right, top: blob.top, bottom: blob.bottom, area: blob.area });
  }

  let scale = 1;
  for (let cell = 0; cell < grid.frameCount; cell++) {
    const bounds = cells.get(cell);
    if (!bounds || bounds.area < width * height * 0.005) {
      // Nothing claimed this cell. Whether a neighbour's drawing is lying across it says which of
      // the two unrecoverable shapes this is, and the redraw is told which one.
      const column = cell % grid.columns, row = Math.floor(cell / grid.columns);
      let strays = 0;
      for (let y = row * height; y < Math.min((row + 1) * height, info.height); y++) {
        for (let x = column * width; x < Math.min((column + 1) * width, info.width); x++) if (keptAt(x, y)) strays++;
      }
      throw new Error(strays > width * height * 0.005
        ? "Cannot recover a sprite sheet without clear gaps between frames"
        : "Cannot recover an empty sprite frame");
    }
    const column = cell % grid.columns, row = Math.floor(cell / grid.columns);
    const cx = (column + 0.5) * width, cy = (row + 0.5) * height;
    scale = Math.min(scale,
      width * 0.35 / Math.max(cx - bounds.left, bounds.right + 1 - cx),
      height * 0.35 / Math.max(cy - bounds.top, bounds.bottom + 1 - cy));
  }

  const tiles = await Promise.all([...cells].map(async ([cell, bounds]) => {
    const tileWidth = bounds.right - bounds.left + 1, tileHeight = bounds.bottom - bounds.top + 1;
    // Copied blob by blob rather than as a rectangle: a neighbour's limb can reach inside this
    // drawing's bounding box, and cutting the box out whole would carry that limb along with it.
    const raw = Buffer.alloc(tileWidth * tileHeight * 4);
    for (let y = 0; y < tileHeight; y++) {
      for (let x = 0; x < tileWidth; x++) {
        const source = (bounds.top + y) * info.width + bounds.left + x;
        const label = labels[source];
        if (label < 0 || owners[label] !== cell) continue;
        const from = source * info.channels, to = (y * tileWidth + x) * 4;
        raw[to] = data[from];
        raw[to + 1] = data[from + 1];
        raw[to + 2] = data[from + 2];
        raw[to + 3] = data[from + info.channels - 1];
      }
    }
    const column = cell % grid.columns, row = Math.floor(cell / grid.columns);
    const cx = (column + 0.5) * width, cy = (row + 0.5) * height;
    const drawnWidth = Math.max(1, Math.round(tileWidth * scale)), drawnHeight = Math.max(1, Math.round(tileHeight * scale));
    return {
      input: await sharp(raw, { raw: { width: tileWidth, height: tileHeight, channels: 4 } })
        .resize(drawnWidth, drawnHeight, { fit: "fill" }).png().toBuffer(),
      // Rounding can put a drawing that exactly fills its cell a pixel over the sheet's edge.
      left: Math.min(Math.max(0, Math.round(cx + (bounds.left - cx) * scale)), info.width - drawnWidth),
      top: Math.min(Math.max(0, Math.round(cy + (bounds.top - cy) * scale)), info.height - drawnHeight),
    };
  }));
  return sharp({ create: { width: info.width, height: info.height, channels: 4, background: "#00000000" } })
    .composite(tiles).png().toBuffer();
}
