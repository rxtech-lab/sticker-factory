/**
 * Assembles an animated PNG from frames `sharp` has already encoded as ordinary PNGs.
 *
 * `sharp` can write animated GIF and WebP but not APNG — libvips' `pngsave` has no animation path —
 * and APNG is the one container the publish contract accepts for an animated sharing rendition
 * (`bindExports` rejects `gif` on a new publish). So the frames are rasterised individually and
 * stitched here, at the chunk level.
 *
 * The stitching is deliberately naive: every frame is stored whole, at the full canvas, with
 * `blend_op = SOURCE`. Real APNG encoders shrink each frame to its dirty rectangle and blend over
 * the previous one, which is smaller but only correct if the delta is computed exactly. A sticker
 * is a few hundred kilobytes of mostly-transparent artwork; paying for whole frames buys a
 * stitcher with no way to produce a subtly wrong animation, and the system rendition's ladder
 * (see `renditions.ts`) already has a size lever that does not involve guessing at deltas.
 */

const SIGNATURE = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (let index = 0; index < bytes.length; index += 1) {
    crc = CRC_TABLE[(crc ^ bytes[index]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** One PNG chunk: length, type, payload, CRC over type+payload. */
function chunk(type: string, payload: Uint8Array): Uint8Array {
  const typeBytes = new TextEncoder().encode(type);
  const out = new Uint8Array(12 + payload.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, payload.length);
  out.set(typeBytes, 4);
  out.set(payload, 8);
  view.setUint32(8 + payload.length, crc32(out.subarray(4, 8 + payload.length)));
  return out;
}

interface ParsedPng {
  /** The IHDR payload, carried across verbatim so every frame keeps frame 0's pixel format. */
  header: Uint8Array;
  width: number;
  height: number;
  /**
   * Chunks between IHDR and the first IDAT that a decoder needs in order to read the pixels —
   * palette and transparency. Colour-management chunks are dropped rather than merged: they are
   * advisory, and carrying one frame's profile onto a stitched file is a claim this code cannot
   * verify.
   */
  preamble: Uint8Array[];
  /** Every IDAT payload of this frame, concatenated. */
  data: Uint8Array;
}

function parsePng(bytes: Uint8Array): ParsedPng {
  for (let index = 0; index < SIGNATURE.length; index += 1) {
    if (bytes[index] !== SIGNATURE[index]) throw new Error("Not a PNG");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const decoder = new TextDecoder();
  const idats: Uint8Array[] = [];
  const preamble: Uint8Array[] = [];
  let header: Uint8Array | undefined;
  let offset = SIGNATURE.length;

  while (offset + 8 <= bytes.length) {
    const length = view.getUint32(offset);
    const type = decoder.decode(bytes.subarray(offset + 4, offset + 8));
    const payload = bytes.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") header = payload;
    else if (type === "IDAT") idats.push(payload);
    else if (type === "PLTE" || type === "tRNS") preamble.push(chunk(type, payload));
    else if (type === "IEND") break;
    offset += 12 + length;
  }
  if (!header || idats.length === 0) throw new Error("PNG has no image data");

  const total = idats.reduce((sum, part) => sum + part.length, 0);
  const data = new Uint8Array(total);
  let cursor = 0;
  for (const part of idats) {
    data.set(part, cursor);
    cursor += part.length;
  }
  const headerView = new DataView(header.buffer, header.byteOffset, header.byteLength);
  return { header, width: headerView.getUint32(0), height: headerView.getUint32(4), preamble, data };
}

function acTl(frameCount: number, playCount: number): Uint8Array {
  const payload = new Uint8Array(8);
  const view = new DataView(payload.buffer);
  view.setUint32(0, frameCount);
  view.setUint32(4, playCount);
  return chunk("acTL", payload);
}

/**
 * A frame's control chunk.
 *
 * `delayMs` is written over a 1/1000 s denominator rather than APNG's conventional 1/100, because
 * a document at 30 fps has a 33 ms frame that hundredths cannot spell — rounding it to 3/100 drifts
 * the cycle about 10% long, which is exactly the kind of mismatch `validateAnimatedRenditionTiming`
 * rejects the export for.
 */
function fcTl(sequence: number, width: number, height: number, delayMs: number): Uint8Array {
  const payload = new Uint8Array(26);
  const view = new DataView(payload.buffer);
  view.setUint32(0, sequence);
  view.setUint32(4, width);
  view.setUint32(8, height);
  view.setUint32(12, 0); // x offset
  view.setUint32(16, 0); // y offset
  view.setUint16(20, Math.max(1, Math.round(delayMs)));
  view.setUint16(22, 1_000);
  payload[24] = 0; // dispose: none — every frame is whole, so there is nothing to clear
  payload[25] = 0; // blend: source — replace the canvas rather than compositing over it
  return chunk("fcTL", payload);
}

function fdAt(sequence: number, data: Uint8Array): Uint8Array {
  const payload = new Uint8Array(4 + data.length);
  new DataView(payload.buffer).setUint32(0, sequence);
  payload.set(data, 4);
  return chunk("fdAT", payload);
}

export interface ApngFrame {
  /** A complete, standalone PNG of this instant, at the same size and pixel format as every other. */
  png: Uint8Array;
  /** How long this frame is shown, in milliseconds. */
  delayMs: number;
}

/**
 * Stitches `frames` into one APNG.
 *
 * @param playCount 0 loops forever, which is what a `loop`/`pingPong` document wants. A play-once
 *   document passes 1 so the sticker settles on its last frame instead of restarting.
 */
export function encodeApng(frames: ApngFrame[], playCount: number): Uint8Array {
  if (frames.length === 0) throw new Error("An APNG needs at least one frame");
  const parsed = frames.map((frame) => parsePng(frame.png));
  const first = parsed[0];
  for (const frame of parsed) {
    if (frame.width !== first.width || frame.height !== first.height) {
      throw new Error("Every APNG frame must share the canvas size");
    }
  }

  const parts: Uint8Array[] = [SIGNATURE, chunk("IHDR", first.header), ...first.preamble];
  parts.push(acTl(parsed.length, playCount));

  let sequence = 0;
  parts.push(fcTl(sequence, first.width, first.height, frames[0].delayMs));
  sequence += 1;
  parts.push(chunk("IDAT", first.data));

  for (let index = 1; index < parsed.length; index += 1) {
    parts.push(fcTl(sequence, first.width, first.height, frames[index].delayMs));
    sequence += 1;
    parts.push(fdAt(sequence, parsed[index].data));
    sequence += 1;
  }
  parts.push(chunk("IEND", new Uint8Array(0)));

  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let cursor = 0;
  for (const part of parts) {
    out.set(part, cursor);
    cursor += part.length;
  }
  return out;
}
