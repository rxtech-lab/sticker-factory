import sharp from "sharp";
import { chromaKeyBackground, preferredChromaKey, type ChromaKeyColor } from "@/lib/ai/chroma-key";
import type { PetRoomFixture, PetRoomFixtures } from "@/lib/db/schema";

/** Rooms are stored once, at the size the tab fills a large phone with. */
export const ROOM_ART_WIDTH = 768;
export const ROOM_ART_HEIGHT = 1152;

/**
 * Below this share of the frame keyed, the model drew no window (or a speck of stray colour);
 * above it, the key colour ran into the room itself. Either way the room is kept whole and opaque
 * rather than shipped with holes the weather would show through.
 */
const MIN_WINDOW_FRACTION = 0.01;
const MAX_WINDOW_FRACTION = 0.4;

/**
 * The flat colours the image model paints a room's blank clock face, weather board and status board
 * in. Neither window key can take them: magenta, cyan and yellow each match green or blue on one
 * rival channel, so none ever runs ahead of the other two the way a window's screen does.
 */
export const ROOM_CLOCK_KEY = { name: "magenta", hex: "#FF00FF", rgb: [255, 0, 255] } as const;
export const ROOM_WEATHER_KEY = { name: "cyan", hex: "#00FFFF", rgb: [0, 255, 255] } as const;
export const ROOM_STATUS_KEY = { name: "yellow", hex: "#FFFF00", rgb: [255, 255, 0] } as const;
type FixtureKey = typeof ROOM_CLOCK_KEY | typeof ROOM_WEATHER_KEY | typeof ROOM_STATUS_KEY;

/** Distance to the key at or under which a pixel is the blank face, and past which it is the room. */
const FACE_DISTANCE = 110;
const EDGE_DISTANCE = 220;
/** A face smaller than a thumbnail is a stray speck; larger than this, the key ran into the room. */
const MIN_FIXTURE_FRACTION = 0.002;
const MAX_FIXTURE_FRACTION = 0.08;
/** The status board holds three gauges, so it is drawn larger than the clock or the weather board. */
const MAX_STATUS_FRACTION = 0.16;
/** How much of its box a face fills: a disc fills ~0.79, so a ragged smear below this is not one. */
const MIN_FIXTURE_FILL = 0.55;
/** The paper the face is repainted toward, so it reads as a blank surface in the room's palette. */
const FACE_PAPER = [247, 240, 226] as const;

/**
 * The screen a room's windows are painted in. Green keys cleanest, but a mossy, leafy room keeps
 * its plants only against blue, so the scene decides, the same way a quick sticker's prompt does.
 */
export function roomWindowKey(scene: string): ChromaKeyColor {
  return preferredChromaKey(scene);
}

/**
 * Cuts the window screen out of a drawn room and stores it as a portrait WebP with alpha, so the
 * app can show the owner's weather through the glass. A room whose key failed stays opaque.
 * The blank clock face, weather board and status board are found and repainted as plain surfaces
 * first, and where they are is returned so the app can write the time, weather and stats onto them.
 */
export async function renderRoomArt(
  bytes: Uint8Array,
  windowKey: ChromaKeyColor,
): Promise<{ bytes: Uint8Array; windowFraction: number; fixtures: PetRoomFixtures }> {
  const painted = await paintRoomFixtures(bytes);
  const keyed = await chromaKeyBackground(painted.bytes, windowKey, { crop: false });
  const usable = keyed.keyedFraction >= MIN_WINDOW_FRACTION && keyed.keyedFraction <= MAX_WINDOW_FRACTION;
  const webp = await sharp(usable ? keyed.bytes : painted.bytes)
    .resize(ROOM_ART_WIDTH, ROOM_ART_HEIGHT, { fit: "cover" })
    .webp({ quality: 86, alphaQuality: 100 })
    .toBuffer();
  return { bytes: new Uint8Array(webp), windowFraction: usable ? keyed.keyedFraction : 0, fixtures: coverFixtures(painted) };
}

/**
 * A place the pet goes, stored like a room but with no windows cut out, since it has its own sky.
 * Its blank clock, weather board and status board are found and repainted the same way.
 */
export async function renderThemeArt(bytes: Uint8Array): Promise<{ bytes: Uint8Array; fixtures: PetRoomFixtures }> {
  const painted = await paintRoomFixtures(bytes);
  const webp = await sharp(painted.bytes)
    .resize(ROOM_ART_WIDTH, ROOM_ART_HEIGHT, { fit: "cover" })
    .webp({ quality: 86 })
    .toBuffer();
  return { bytes: new Uint8Array(webp), fixtures: coverFixtures(painted) };
}

function coverFixtures(painted: Awaited<ReturnType<typeof paintRoomFixtures>>): PetRoomFixtures {
  const cover = (fixture: PetRoomFixture | null) => fixture && intoCover(fixture, painted.width, painted.height);
  return { clock: cover(painted.clock), weather: cover(painted.weather), status: cover(painted.status) };
}

/**
 * Finds the clock face, weather board and status board the model left blank in their key colours,
 * and paints each over as a light surface tinted by the frame around it, with an ink from that
 * frame to write on it in. A key the model forgot, smeared, or spilled across the room gives no
 * fixture, and the app keeps the time, weather and stats in its own chips and card for that room.
 */
export async function paintRoomFixtures(bytes: Uint8Array): Promise<{
  bytes: Uint8Array; width: number; height: number;
  clock: PetRoomFixture | null; weather: PetRoomFixture | null; status: PetRoomFixture | null;
}> {
  const { data, info } = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const clock = paintFixture(data, info.width, info.height, ROOM_CLOCK_KEY);
  const weather = paintFixture(data, info.width, info.height, ROOM_WEATHER_KEY);
  const status = paintFixture(data, info.width, info.height, ROOM_STATUS_KEY, MAX_STATUS_FRACTION);
  const png = clock || weather || status
    ? await sharp(data, { raw: { width: info.width, height: info.height, channels: 4 } }).png().toBuffer()
    : bytes;
  return { bytes: new Uint8Array(png), width: info.width, height: info.height, clock, weather, status };
}

function keyDistance(data: Buffer, offset: number, key: FixtureKey): number {
  const r = data[offset] - key.rgb[0];
  const g = data[offset + 1] - key.rgb[1];
  const b = data[offset + 2] - key.rgb[2];
  return Math.sqrt(r * r + g * g + b * b);
}

/** Labels the largest blob of `key`, repaints it in place, and describes it; null when there is none worth writing on. */
function paintFixture(
  data: Buffer, width: number, height: number, key: FixtureKey, maxFraction = MAX_FIXTURE_FRACTION,
): PetRoomFixture | null {
  const size = width * height;
  const face = new Uint8Array(size);
  for (let pixel = 0; pixel < size; pixel += 1) {
    if (keyDistance(data, pixel * 4, key) <= FACE_DISTANCE) face[pixel] = 1;
  }
  // The largest connected blob is the face; specks of the key elsewhere are left as drawn.
  const label = new Int32Array(size);
  const stack = new Int32Array(size);
  let best = { id: 0, count: 0, minX: 0, minY: 0, maxX: 0, maxY: 0 };
  let next = 0;
  for (let start = 0; start < size; start += 1) {
    if (!face[start] || label[start]) continue;
    next += 1;
    let top = 0;
    stack[top++] = start;
    label[start] = next;
    const blob = { id: next, count: 0, minX: width, minY: height, maxX: 0, maxY: 0 };
    while (top) {
      const pixel = stack[--top];
      const x = pixel % width;
      const y = (pixel - x) / width;
      blob.count += 1;
      if (x < blob.minX) blob.minX = x;
      if (x > blob.maxX) blob.maxX = x;
      if (y < blob.minY) blob.minY = y;
      if (y > blob.maxY) blob.maxY = y;
      for (const neighbour of [x > 0 ? pixel - 1 : -1, x < width - 1 ? pixel + 1 : -1,
        y > 0 ? pixel - width : -1, y < height - 1 ? pixel + width : -1]) {
        if (neighbour >= 0 && face[neighbour] && !label[neighbour]) {
          label[neighbour] = next;
          stack[top++] = neighbour;
        }
      }
    }
    if (blob.count > best.count) best = blob;
  }
  if (!best.count) return null;
  const boxWidth = best.maxX - best.minX + 1;
  const boxHeight = best.maxY - best.minY + 1;
  const fill = best.count / (boxWidth * boxHeight);
  const fraction = best.count / size;
  if (fraction < MIN_FIXTURE_FRACTION || fraction > maxFraction || fill < MIN_FIXTURE_FILL) return null;

  // The frame: what was drawn just outside the face, which sets its tint and the ink written on it.
  const margin = Math.max(4, Math.round(Math.min(boxWidth, boxHeight) * 0.08));
  const x0 = Math.max(0, best.minX - margin);
  const y0 = Math.max(0, best.minY - margin);
  const x1 = Math.min(width - 1, best.maxX + margin);
  const y1 = Math.min(height - 1, best.maxY + margin);
  // Only the ring hugging the face counts, so a round clock's frame is not averaged with the wall
  // showing in the corners of its box.
  const reach = Math.max(3, Math.round(margin / 2));
  const hugs = (x: number, y: number) =>
    (x >= reach && label[y * width + x - reach] === best.id) ||
    (x + reach < width && label[y * width + x + reach] === best.id) ||
    (y >= reach && label[(y - reach) * width + x] === best.id) ||
    (y + reach < height && label[(y + reach) * width + x] === best.id);
  const frame = [0, 0, 0];
  let framed = 0;
  for (let y = y0; y <= y1; y += 1) {
    for (let x = x0; x <= x1; x += 1) {
      const offset = (y * width + x) * 4;
      if (keyDistance(data, offset, key) <= EDGE_DISTANCE || !hugs(x, y)) continue;
      frame[0] += data[offset];
      frame[1] += data[offset + 1];
      frame[2] += data[offset + 2];
      framed += 1;
    }
  }
  const rim = framed ? frame.map((sum) => sum / framed) : [120, 96, 72];
  const surface = FACE_PAPER.map((paper, channel) => Math.round(paper * 0.82 + rim[channel] * 0.18));
  const rimLight = luminance(rim);
  // Dark frames lend the ink their own colour; light ones are deepened until the writing reads.
  const inkScale = rimLight > 0.28 ? 0.28 / Math.max(rimLight, 0.01) : 1;
  const ink = rim.map((channel) => Math.round(channel * inkScale));

  // Painted over, with the antialiased rim blended toward the surface by how much key it carries.
  for (let y = y0; y <= y1; y += 1) {
    for (let x = x0; x <= x1; x += 1) {
      const offset = (y * width + x) * 4;
      const distance = keyDistance(data, offset, key);
      const weight = label[y * width + x] === best.id ? 1
        : Math.min(1, Math.max(0, (EDGE_DISTANCE - distance) / (EDGE_DISTANCE - FACE_DISTANCE)));
      if (!weight) continue;
      for (let channel = 0; channel < 3; channel += 1) {
        data[offset + channel] = Math.round(data[offset + channel] * (1 - weight) + surface[channel] * weight);
      }
    }
  }
  return {
    x: best.minX, y: best.minY, width: boxWidth, height: boxHeight,
    shape: fill < 0.86 ? "round" : "rect",
    face: hex(surface), ink: hex(ink),
  };
}

/** Pixel box in the drawing to a 0–1 box in the stored room, which `cover` crops to its own shape. */
function intoCover(fixture: PetRoomFixture, width: number, height: number): PetRoomFixture {
  const scale = Math.max(ROOM_ART_WIDTH / width, ROOM_ART_HEIGHT / height);
  const offsetX = (width * scale - ROOM_ART_WIDTH) / 2;
  const offsetY = (height * scale - ROOM_ART_HEIGHT) / 2;
  const round = (value: number) => Math.round(Math.min(1, Math.max(0, value)) * 10_000) / 10_000;
  return {
    ...fixture,
    x: round((fixture.x * scale - offsetX) / ROOM_ART_WIDTH),
    y: round((fixture.y * scale - offsetY) / ROOM_ART_HEIGHT),
    width: round((fixture.width * scale) / ROOM_ART_WIDTH),
    height: round((fixture.height * scale) / ROOM_ART_HEIGHT),
  };
}

function luminance([r, g, b]: number[]): number {
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

function hex(rgb: number[]): string {
  return `#${rgb.map((channel) => Math.round(channel).toString(16).padStart(2, "0")).join("").toUpperCase()}`;
}
