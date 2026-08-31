/**
 * An APNG built by splicing animation control chunks into a still PNG.
 *
 * libvips has no APNG encoder, so sharp cannot produce one and there is nothing to generate these
 * fixtures with. Building the chunks by hand rather than checking in a binary keeps the fixture
 * legible, and it is faithful to what the inspector actually reads: `readApngTiming` in
 * `lib/storage/r2.ts` counts `fcTL` chunks and sums their delays without decoding a pixel.
 *
 * The frames are a fiction — every control chunk points at the same default image — but the chunk
 * layout is the real one. `acTL` and `fcTL` are ancillary, so a decoder that does not know them
 * skips them and still sees a valid PNG, which is what keeps libpng happy about the result.
 */

const crcTable = Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

function chunk(type: string, payload: Buffer): Buffer {
  const typed = Buffer.concat([Buffer.from(type, "ascii"), payload]);
  let crc = 0xffffffff;
  for (const byte of typed) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(payload.byteLength);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, typed, checksum]);
}

/**
 * @param declaredFrames what `acTL` claims, which a test may set higher than the control chunks
 *   actually present to prove the inspector counts what it carries rather than what it promises.
 */
export function spliceApngControlChunks(
  png: Buffer,
  delaysMilliseconds: number[],
  declaredFrames = delaysMilliseconds.length,
  dimension = 300,
): Buffer {
  const control = Buffer.alloc(8);
  control.writeUInt32BE(declaredFrames, 0);
  control.writeUInt32BE(0, 4);
  const chunks = [chunk("acTL", control)];
  delaysMilliseconds.forEach((delay, index) => {
    const payload = Buffer.alloc(26);
    payload.writeUInt32BE(index, 0);
    payload.writeUInt32BE(dimension, 4);
    payload.writeUInt32BE(dimension, 8);
    payload.writeUInt32BE(0, 12);
    payload.writeUInt32BE(0, 16);
    payload.writeUInt16BE(delay, 20);
    payload.writeUInt16BE(1000, 22);
    chunks.push(chunk("fcTL", payload));
  });

  const idat = png.indexOf(Buffer.from("IDAT", "ascii")) - 4;
  return Buffer.concat([png.subarray(0, idat), ...chunks, png.subarray(idat)]);
}
