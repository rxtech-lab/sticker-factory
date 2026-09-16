import sharp from "sharp";

/** Invalid generated artwork can be redrawn; decoding, storage and provider errors cannot. */
export class SpriteSheetValidationError extends Error {
  constructor(readonly reason: "clipped" | "empty" | "face-placeholder", message: string) {
    super(message);
    this.name = "SpriteSheetValidationError";
  }
}

type Grid = { columns: number; rows: number; frameCount: number };

/**
 * Recover intact drawings that stray across the nominal grid. Only cut along clear alpha gaps;
 * touching/overlapping subjects and artwork clipped by the image itself cannot be recovered.
 * A single scale and the original nominal cell anchors preserve motion between frames.
 */
export async function padGeneratedAtlas(bytes: Uint8Array, grid: Grid): Promise<Uint8Array> {
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const width = Math.floor(info.width / grid.columns), height = Math.floor(info.height / grid.rows);
  const visible = (x: number, y: number) => data[(y * info.width + x) * info.channels + info.channels - 1] > 24;
  if (Array.from({ length: info.width }, (_, x) => visible(x, 0) || visible(x, info.height - 1)).some(Boolean)
    || Array.from({ length: info.height }, (_, y) => visible(0, y) || visible(info.width - 1, y)).some(Boolean)) {
    throw new Error("Cannot recover a sprite sheet clipped at its outer edge");
  }

  // Search close to the intended boundary, never far enough to consume an adjacent frame.
  const seam = (target: number, span: number, clear: (position: number) => boolean): number => {
    for (let distance = 0; distance <= Math.floor(span * 0.2); distance++) {
      for (const position of distance === 0 ? [target] : [target - distance, target + distance]) {
        if (clear(position)) return position;
      }
    }
    throw new Error("Cannot recover a sprite sheet without clear gaps between frames");
  };
  const ys = [0];
  for (let row = 1; row < grid.rows; row++) {
    ys.push(seam(row * height, height, (y) => {
      for (let x = 0; x < info.width; x++) if (visible(x, y)) return false;
      return true;
    }));
  }
  ys.push(info.height);

  const cells: { left: number; top: number; width: number; height: number; column: number; row: number }[] = [];
  let scale = 1;
  for (let row = 0; row < grid.rows; row++) {
    const xs = [0];
    for (let column = 1; column < grid.columns; column++) {
      xs.push(seam(column * width, width, (x) => {
        for (let y = ys[row]; y < ys[row + 1]; y++) if (visible(x, y)) return false;
        return true;
      }));
    }
    xs.push(info.width);
    for (let column = 0; column < grid.columns; column++) {
      const cell = { left: xs[column], top: ys[row], width: xs[column + 1] - xs[column], height: ys[row + 1] - ys[row], column, row };
      let count = 0;
      for (let y = cell.top; y < cell.top + cell.height; y++) {
        for (let x = cell.left; x < cell.left + cell.width; x++) if (visible(x, y)) count++;
      }
      if (row * grid.columns + column >= grid.frameCount) {
        if (count) throw new Error("Cannot recover a sprite sheet with artwork in unused cells");
        continue;
      }
      if (count < width * height * 0.005) throw new Error("Cannot recover an empty sprite frame");
      const cx = (column + 0.5) * width, cy = (row + 0.5) * height;
      scale = Math.min(scale,
        width * 0.35 / Math.max(cx - cell.left, cell.left + cell.width - cx),
        height * 0.35 / Math.max(cy - cell.top, cell.top + cell.height - cy));
      cells.push(cell);
    }
  }
  const tiles = await Promise.all(cells.map(async (cell) => ({
    input: await sharp(bytes).extract({ left: cell.left, top: cell.top, width: cell.width, height: cell.height })
      .resize(Math.max(1, Math.round(cell.width * scale)), Math.max(1, Math.round(cell.height * scale)), { fit: "fill" }).png().toBuffer(),
    left: Math.round(cell.column * width + width / 2 + (cell.left - (cell.column + 0.5) * width) * scale),
    top: Math.round(cell.row * height + height / 2 + (cell.top - (cell.row + 0.5) * height) * scale),
  })));
  return sharp({ create: { width: info.width, height: info.height, channels: 4, background: "#00000000" } })
    .composite(tiles).png().toBuffer();
}
