import { createHash } from "node:crypto";
import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import sharp, { type Metadata, type Stats } from "sharp";
import { MAX_RENDITION_SECONDS, RENDITION_TIMING_EPSILON_SECONDS } from "@/lib/contracts/sticker";
import { ApiError } from "@/lib/http/errors";
import { cropPngToSubject, type SubjectBounds } from "@/lib/images/subject-bounds";

export interface StoredObject {
  bytes: Uint8Array;
  contentType: string;
  metadata?: Record<string, string>;
}

export interface ObjectStore {
  signedPut(key: string, contentType: string, byteSize: number): Promise<{ url: string; expiresAt: Date; headers: Record<string, string> }>;
  /**
   * A presigned read. Five minutes by default, which is a download's worth; a caller handing the
   * URL to a third party that queues before it fetches — a video model — may ask for longer.
   */
  signedGet(key: string, filename?: string, expiresInSeconds?: number): Promise<{ url: string; expiresAt: Date }>;
  put(key: string, object: StoredObject): Promise<void>;
  get(key: string): Promise<StoredObject>;
  head(key: string): Promise<{ contentType?: string; byteSize?: number; metadata?: Record<string, string> }>;
  delete(key: string): Promise<void>;
}

class R2ObjectStore implements ObjectStore {
  private readonly client: S3Client;
  private readonly bucket: string;

  constructor() {
    const accountId = process.env.R2_ACCOUNT_ID;
    const accessKeyId = process.env.R2_ACCESS_KEY_ID;
    const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
    const bucket = process.env.R2_BUCKET;
    if (!accountId || !accessKeyId || !secretAccessKey || !bucket) {
      throw new ApiError(503, "STORAGE_NOT_CONFIGURED", "Cloudflare R2 is not configured");
    }
    this.bucket = bucket;
    this.client = new S3Client({
      region: "auto",
      endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
      credentials: { accessKeyId, secretAccessKey },
    });
  }

  async signedPut(key: string, contentType: string, byteSize: number) {
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000);
    const command = new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ContentType: contentType,
      ContentLength: byteSize,
    });
    return {
      url: await getSignedUrl(this.client, command, { expiresIn: 600 }),
      expiresAt,
      headers: { "content-type": contentType },
    };
  }

  async signedGet(key: string, filename?: string, expiresInSeconds = 300) {
    const expiresAt = new Date(Date.now() + expiresInSeconds * 1000);
    const safeFilename = filename?.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120) || "sticker";
    const command = new GetObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ...(filename ? { ResponseContentDisposition: `attachment; filename="${safeFilename}"` } : {}),
    });
    return { url: await getSignedUrl(this.client, command, { expiresIn: expiresInSeconds }), expiresAt };
  }

  async put(key: string, object: StoredObject): Promise<void> {
    await this.client.send(new PutObjectCommand({
      Bucket: this.bucket,
      Key: key,
      Body: object.bytes,
      ContentType: object.contentType,
      Metadata: object.metadata,
    }));
  }

  async get(key: string): Promise<StoredObject> {
    const result = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }));
    if (!result.Body) throw new ApiError(404, "ASSET_OBJECT_MISSING", "The media object does not exist");
    return {
      bytes: await result.Body.transformToByteArray(),
      contentType: result.ContentType ?? "application/octet-stream",
      metadata: result.Metadata,
    };
  }

  async head(key: string) {
    const result = await this.client.send(new HeadObjectCommand({ Bucket: this.bucket, Key: key }));
    return { contentType: result.ContentType, byteSize: result.ContentLength, metadata: result.Metadata };
  }

  async delete(key: string): Promise<void> {
    await this.client.send(new DeleteObjectCommand({ Bucket: this.bucket, Key: key }));
  }
}

export class MemoryObjectStore implements ObjectStore {
  readonly objects = new Map<string, StoredObject>();

  async signedPut(key: string, contentType: string, byteSize: number) {
    return {
      url: `https://uploads.invalid/${encodeURIComponent(key)}?size=${byteSize}`,
      expiresAt: new Date(Date.now() + 600_000),
      headers: { "content-type": contentType },
    };
  }
  async signedGet(key: string, filename?: string, expiresInSeconds = 300) {
    if (!this.objects.has(key) && process.env.STICKER_FACTORY_E2E !== "true") {
      throw new ApiError(404, "ASSET_OBJECT_MISSING", "The media object does not exist");
    }
    return {
      url: filename
        ? `https://downloads.invalid/${encodeURIComponent(key)}?disposition=${encodeURIComponent(`attachment; filename="${filename}"`)}`
        : `https://downloads.invalid/${encodeURIComponent(key)}?mode=inline`,
      expiresAt: new Date(Date.now() + expiresInSeconds * 1000),
    };
  }
  async put(key: string, object: StoredObject) { this.objects.set(key, object); }
  async get(key: string) {
    const object = this.objects.get(key);
    if (!object) throw new ApiError(404, "ASSET_OBJECT_MISSING", "The media object does not exist");
    return object;
  }
  async head(key: string) {
    const object = await this.get(key);
    return { contentType: object.contentType, byteSize: object.bytes.byteLength, metadata: object.metadata };
  }
  async delete(key: string) { this.objects.delete(key); }
}

let testStore: ObjectStore | undefined;
let r2Store: ObjectStore | undefined;

export function setObjectStoreForTests(store?: ObjectStore): void {
  testStore = store;
}

export function getObjectStore(): ObjectStore {
  if (testStore) return testStore;
  if (process.env.NODE_ENV === "test"
    || (process.env.NODE_ENV !== "production" && process.env.STICKER_FACTORY_MOCK_SERVICES === "true")) {
    testStore = new MemoryObjectStore();
    return testStore;
  }
  r2Store ??= new R2ObjectStore();
  return r2Store;
}

export interface ImageInspection {
  width: number;
  height: number;
  mimeType: "image/png" | "image/jpeg" | "image/webp" | "image/gif";
  hasAlpha: boolean;
  hasTransparentPixels: boolean;
  hasNonTransparentPixels: boolean;
  frameCount: number;
  durationSeconds: number;
  fps: number;
  sha256: string;
  byteSize: number;
}

export interface Mp4Inspection {
  width: number;
  height: number;
  codec: "avc1" | "avc3";
  frameCount: number;
  durationSeconds: number;
  fps: number;
  sha256: string;
  byteSize: number;
}

/**
 * What can be learned about a WebM without decoding it.
 *
 * No `frameCount` or `fps`: those live in the cluster blocks, which means walking every frame of
 * the file to count them, and nothing checks them — Telegram's rule is about duration and size.
 */
export interface WebMInspection {
  width: number;
  height: number;
  codec: "V_VP9";
  durationSeconds: number;
  sha256: string;
  byteSize: number;
}

function findAscii(bytes: Uint8Array, needle: string, start = 0): number {
  const pattern = new TextEncoder().encode(needle);
  outer: for (let index = start; index <= bytes.length - pattern.length; index += 1) {
    for (let offset = 0; offset < pattern.length; offset += 1) {
      if (bytes[index + offset] !== pattern[offset]) continue outer;
    }
    return index;
  }
  return -1;
}

interface AtomRange {
  typeOffset: number;
  start: number;
  end: number;
  dataStart: number;
}

function findAtoms(bytes: Uint8Array, type: string, start = 0, end = bytes.byteLength): AtomRange[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const atoms: AtomRange[] = [];
  let cursor = start;
  while (cursor < end) {
    const typeOffset = findAscii(bytes, type, cursor);
    if (typeOffset < 4 || typeOffset >= end) break;
    const atomStart = typeOffset - 4;
    const size32 = view.getUint32(atomStart);
    let atomSize = size32;
    let dataStart = typeOffset + 4;
    if (size32 === 1 && typeOffset + 12 <= bytes.byteLength) {
      const extended = view.getBigUint64(typeOffset + 4);
      if (extended <= BigInt(Number.MAX_SAFE_INTEGER)) {
        atomSize = Number(extended);
        dataStart = typeOffset + 12;
      }
    }
    const atomEnd = atomStart + atomSize;
    if (atomSize >= dataStart - atomStart && atomStart >= start && atomEnd <= end) {
      atoms.push({ typeOffset, start: atomStart, end: atomEnd, dataStart });
    }
    cursor = typeOffset + 4;
  }
  return atoms;
}

function readTrackTiming(bytes: Uint8Array, track: AtomRange): { frameCount: number; durationSeconds: number; fps: number } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const mdhd = findAtoms(bytes, "mdhd", track.dataStart, track.end)[0];
  const stts = findAtoms(bytes, "stts", track.dataStart, track.end)[0];
  if (!mdhd || !stts) throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 frame timing could not be verified");

  const version = view.getUint8(mdhd.dataStart);
  let timescale: number;
  let duration: number;
  if (version === 0 && mdhd.dataStart + 20 <= mdhd.end) {
    timescale = view.getUint32(mdhd.dataStart + 12);
    duration = view.getUint32(mdhd.dataStart + 16);
  } else if (version === 1 && mdhd.dataStart + 32 <= mdhd.end) {
    timescale = view.getUint32(mdhd.dataStart + 20);
    const rawDuration = view.getBigUint64(mdhd.dataStart + 24);
    if (rawDuration > BigInt(Number.MAX_SAFE_INTEGER)) throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 duration is out of range");
    duration = Number(rawDuration);
  } else {
    throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 media timing is invalid");
  }
  if (!timescale || !duration) throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 media duration is invalid");

  if (stts.dataStart + 8 > stts.end) throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 sample timing is invalid");
  const entryCount = view.getUint32(stts.dataStart + 4);
  if (entryCount < 1 || entryCount > 100_000 || stts.dataStart + 8 + entryCount * 8 > stts.end) {
    throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 sample timing table is invalid");
  }
  let frameCount = 0;
  for (let index = 0; index < entryCount; index += 1) {
    frameCount += view.getUint32(stts.dataStart + 8 + index * 8);
  }
  const durationSeconds = duration / timescale;
  const fps = frameCount / durationSeconds;
  if (!Number.isFinite(durationSeconds) || !Number.isFinite(fps) || frameCount < 1) {
    throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 frame timing is invalid");
  }
  return { frameCount, durationSeconds, fps };
}

export function inspectMp4(bytes: Uint8Array): Mp4Inspection {
  if (bytes.byteLength < 64 || findAscii(bytes.subarray(0, 32), "ftyp") !== 4) {
    throw new ApiError(422, "INVALID_MP4", "The export is not an ISO BMFF MP4 file");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const videoTrack = findAtoms(bytes, "trak").find((track) =>
    findAtoms(bytes, "avc1", track.dataStart, track.end).length > 0
      || findAtoms(bytes, "avc3", track.dataStart, track.end).length > 0);
  if (!videoTrack) throw new ApiError(422, "INVALID_MP4_CODEC", "MP4 exports must contain an H.264 video track");
  const codec: Mp4Inspection["codec"] = findAtoms(bytes, "avc1", videoTrack.dataStart, videoTrack.end).length > 0 ? "avc1" : "avc3";
  const tkhd = findAtoms(bytes, "tkhd", videoTrack.dataStart, videoTrack.end)[0];
  let width = 0;
  let height = 0;
  if (tkhd && tkhd.end - tkhd.start >= 16) {
    width = Math.round(view.getUint32(tkhd.end - 8) / 65_536);
    height = Math.round(view.getUint32(tkhd.end - 4) / 65_536);
  }
  if (!width || !height) throw new ApiError(422, "INVALID_MP4_DIMENSIONS", "MP4 video dimensions could not be verified");
  const timing = readTrackTiming(bytes, videoTrack);
  // The ceiling is the longest cycle plus its loop hold, which an MP4 carries as repeated frames —
  // the same bound the sharing and system renditions are held to. A flat 8 here rejected the longest
  // stickers for being exactly as long as they are supposed to be.
  if (timing.durationSeconds < 0.5 - RENDITION_TIMING_EPSILON_SECONDS || timing.durationSeconds > MAX_RENDITION_SECONDS + RENDITION_TIMING_EPSILON_SECONDS || timing.fps > 30.01) {
    throw new ApiError(422, "INVALID_MP4_TIMING", `MP4 exports must be 0.5–${MAX_RENDITION_SECONDS} seconds at no more than 30 FPS`);
  }
  return {
    width,
    height,
    codec,
    ...timing,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    byteSize: bytes.byteLength,
  };
}

/**
 * Dimensions, codec and duration for a WebM, read straight out of its EBML elements.
 *
 * There is no decoder anywhere in this codebase that could open one — the server has sharp and
 * nothing else — but nothing else needs to be opened to answer the only questions that matter: is
 * this VP9, is it the 512 px square Telegram demands, and is it inside three seconds. Every other
 * rendition has its pixels measured rather than taken on trust, and a WebM that lies about its size
 * is not rejected here but by Telegram, *after* the hand-off, where the person who made the pack
 * has no way to find out why.
 *
 * The one thing this deliberately does not verify is the alpha side-stream. Telegram wants
 * transparency, the encoder writes it as a second VP9 stream in each block's `BlockAdditional`, and
 * confirming it is really there means decoding a frame. Container, codec, dimensions and duration
 * are what this admits.
 */
export function inspectWebM(bytes: Uint8Array): WebMInspection {
  if (bytes.byteLength < 64 || bytes[0] !== 0x1a || bytes[1] !== 0x45 || bytes[2] !== 0xdf || bytes[3] !== 0xa3) {
    throw new ApiError(422, "INVALID_WEBM", "The rendition is not a Matroska/WebM file");
  }
  const segment = findEbmlChild(bytes, { start: 0, end: bytes.byteLength }, EBML_SEGMENT);
  if (!segment) throw new ApiError(422, "INVALID_WEBM", "The WebM file has no segment");

  // Duration is stored in timecode units, so it means nothing without the scale beside it. The
  // 1 ms default is Matroska's own, and is what every file this app produces uses.
  const info = findEbmlChild(bytes, segment, EBML_INFO);
  const timecodeScale = info ? readEbmlUint(bytes, findEbmlChild(bytes, info, EBML_TIMECODE_SCALE)) ?? 1_000_000 : 1_000_000;
  const rawDuration = info ? readEbmlFloat(bytes, findEbmlChild(bytes, info, EBML_DURATION)) : undefined;
  const durationSeconds = rawDuration === undefined ? 0 : (rawDuration * timecodeScale) / 1_000_000_000;

  const tracks = findEbmlChild(bytes, segment, EBML_TRACKS);
  if (!tracks) throw new ApiError(422, "INVALID_WEBM", "The WebM file has no track list");
  let width = 0;
  let height = 0;
  let codec = "";
  for (const entry of findEbmlChildren(bytes, tracks, EBML_TRACK_ENTRY)) {
    const video = findEbmlChild(bytes, entry, EBML_VIDEO);
    if (!video) continue;
    codec = readEbmlString(bytes, findEbmlChild(bytes, entry, EBML_CODEC_ID)) ?? "";
    width = readEbmlUint(bytes, findEbmlChild(bytes, video, EBML_PIXEL_WIDTH)) ?? 0;
    height = readEbmlUint(bytes, findEbmlChild(bytes, video, EBML_PIXEL_HEIGHT)) ?? 0;
    break;
  }
  if (codec !== "V_VP9") throw new ApiError(422, "INVALID_WEBM_CODEC", "WebM renditions must carry a VP9 video track");
  if (!width || !height) throw new ApiError(422, "INVALID_WEBM_DIMENSIONS", "WebM video dimensions could not be verified");
  return {
    width,
    height,
    codec: "V_VP9",
    durationSeconds,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    byteSize: bytes.byteLength,
  };
}

// The handful of EBML ids this reader walks, each written as the full id including its length
// marker, which is how they appear in the byte stream.
const EBML_SEGMENT = 0x18538067;
const EBML_INFO = 0x1549a966;
const EBML_TIMECODE_SCALE = 0x2ad7b1;
const EBML_DURATION = 0x4489;
const EBML_TRACKS = 0x1654ae6b;
const EBML_TRACK_ENTRY = 0xae;
const EBML_VIDEO = 0xe0;
const EBML_CODEC_ID = 0x86;
const EBML_PIXEL_WIDTH = 0xb0;
const EBML_PIXEL_HEIGHT = 0xba;

interface EbmlRange {
  start: number;
  end: number;
}

/**
 * One EBML variable-length integer at `offset`.
 *
 * The leading zero bits count the extra bytes; the first set bit is the marker. Ids keep that
 * marker (it is part of the id), sizes drop it (it is only a length prefix) — which is the whole
 * difference between the two calls below.
 */
function readVarInt(bytes: Uint8Array, offset: number, keepMarker: boolean): { value: number; next: number; unknown: boolean } | null {
  if (offset >= bytes.byteLength) return null;
  const first = bytes[offset];
  if (first === 0) return null;
  let length = 1;
  while (length <= 8 && (first & (0x80 >> (length - 1))) === 0) length += 1;
  if (length > 8 || offset + length > bytes.byteLength) return null;
  let value = keepMarker ? first : first & (0xff >> length);
  for (let index = 1; index < length; index += 1) value = value * 256 + bytes[offset + index];
  // A size with every value bit set means "unknown, runs to the end of the parent". Seven bits per
  // byte survive the length marker, so that is 2^(7·length) − 1 and nothing else.
  const unknown = !keepMarker && value === Math.pow(2, 7 * length) - 1;
  return { value, next: offset + length, unknown };
}

/** Every direct child of `range` carrying `id`, in order. */
function findEbmlChildren(bytes: Uint8Array, range: EbmlRange, id: number): EbmlRange[] {
  const found: EbmlRange[] = [];
  let cursor = range.start;
  while (cursor < range.end) {
    const element = readVarInt(bytes, cursor, true);
    if (!element) break;
    const size = readVarInt(bytes, element.next, false);
    if (!size) break;
    // An unknown-length element runs to the end of its parent. Only the segment is ever written
    // that way — a live muxer that does not yet know how long the file will be — and treating it as
    // "the rest" is exactly right for it.
    const end = Math.min(size.unknown ? range.end : size.next + size.value, range.end);
    if (end < size.next) break;
    if (element.value === id) found.push({ start: size.next, end });
    cursor = end;
  }
  return found;
}

function findEbmlChild(bytes: Uint8Array, range: EbmlRange, id: number): EbmlRange | undefined {
  return findEbmlChildren(bytes, range, id)[0];
}

function readEbmlUint(bytes: Uint8Array, range: EbmlRange | undefined): number | undefined {
  if (!range || range.end <= range.start || range.end - range.start > 8) return undefined;
  let value = 0;
  for (let index = range.start; index < range.end; index += 1) value = value * 256 + bytes[index];
  return value;
}

function readEbmlFloat(bytes: Uint8Array, range: EbmlRange | undefined): number | undefined {
  if (!range) return undefined;
  const size = range.end - range.start;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (size === 4) return view.getFloat32(range.start);
  if (size === 8) return view.getFloat64(range.start);
  return undefined;
}

function readEbmlString(bytes: Uint8Array, range: EbmlRange | undefined): string | undefined {
  if (!range) return undefined;
  // Matroska pads fixed-width strings with NULs; `V_VP9\0` and `V_VP9` are the same codec.
  return new TextDecoder().decode(bytes.subarray(range.start, range.end)).replace(/\0+$/, "");
}

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/**
 * Frame timing for an animated PNG, read straight out of its chunks.
 *
 * libvips has no APNG decoder — sharp reports an eight-frame sticker as a single-page PNG with no
 * delays — so an APNG rendition would otherwise arrive looking static and be rejected as one. The
 * chunks carry everything the validator needs without decoding a pixel: `acTL` counts the frames and
 * each `fcTL` carries that frame's delay as a rational.
 *
 * Returns `null` for a plain PNG, which is not an error: it means the caller keeps sharp's answer.
 */
export function readApngTiming(bytes: Uint8Array): { frameCount: number; durationSeconds: number } | null {
  if (bytes.byteLength < 8 || PNG_SIGNATURE.some((byte, index) => bytes[index] !== byte)) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const decoder = new TextDecoder("ascii");
  let cursor = 8;
  let declaredFrames: number | null = null;
  let controlCount = 0;
  let durationSeconds = 0;
  while (cursor + 8 <= bytes.byteLength) {
    const length = view.getUint32(cursor);
    const type = decoder.decode(bytes.subarray(cursor + 4, cursor + 8));
    const dataStart = cursor + 8;
    if (length > bytes.byteLength || dataStart + length + 4 > bytes.byteLength) break;
    if (type === "acTL" && length >= 8) {
      declaredFrames = view.getUint32(dataStart);
    } else if (type === "fcTL" && length >= 26) {
      controlCount += 1;
      const delayNumerator = view.getUint16(dataStart + 20);
      // A zero denominator means hundredths of a second; the spec spells this out because 0/0 is
      // how encoders ask for "as fast as possible".
      const delayDenominator = view.getUint16(dataStart + 22) || 100;
      durationSeconds += delayNumerator / delayDenominator;
    } else if (type === "IEND") {
      break;
    }
    cursor = dataStart + length + 4;
  }
  if (declaredFrames === null || controlCount === 0) return null;
  // The frame count is taken from the control chunks actually present rather than from `acTL`, so a
  // file that promises more frames than it carries cannot inflate its own timing.
  return { frameCount: Math.min(declaredFrames, controlCount), durationSeconds };
}

function formatToMime(format?: string): ImageInspection["mimeType"] {
  if (format === "png") return "image/png";
  if (format === "jpeg") return "image/jpeg";
  if (format === "webp") return "image/webp";
  if (format === "gif") return "image/gif";
  throw new ApiError(422, "UNSUPPORTED_IMAGE", "The uploaded file is not a supported image");
}

/**
 * The largest single frame this will inspect — and the only pixel bound there is.
 *
 * Frame *count* is deliberately unbounded. It used to be capped at 240, which was below the app's
 * own contracts and so rejected legal work: a sharing APNG is admitted at up to
 * `MAX_RENDITION_SECONDS` (8.6 s) at 30 FPS, which is 258 frames, and the client saw
 * `TOO_MANY_IMAGE_FRAMES` for a file the validator that owns that decision would have accepted.
 * Any fixed replacement has the same failure mode one product decision later, so there is no
 * replacement — what bounds an animation is the rule that describes it, not a number here.
 *
 * That is safe because nothing in this file decodes an animation whole, and neither does anything
 * downstream: `metadata()` reads headers, `readApngTiming` walks chunks without touching a pixel,
 * the stats pass below composites exactly one frame, and `downscaleForModelInput` opens page 0. So
 * the cost of a frame count is its delay array and its chunk walk, both linear in a file the upload
 * contract already caps at 25 MB. Per-frame area is the one thing that reaches a decoder, which is
 * what this bounds — matching the 4096-per-side rule `validateImageForKind` holds every kind to.
 *
 * The bounds that actually shape a rendition live in `lib/services/assets.ts`, per kind, and every
 * animated one of them is stricter than anything this could say: duration, frame rate, dimensions
 * and byte size, each measured against the document the export came from.
 */
const MAX_FRAME_PIXELS = 4096 * 4096;

export async function inspectImage(bytes: Uint8Array): Promise<ImageInspection> {
  let metadata: Metadata;
  let stats: Stats;
  try {
    metadata = await sharp(bytes, { animated: true, limitInputPixels: false }).metadata();
  } catch {
    throw new ApiError(422, "INVALID_IMAGE", "The image could not be decoded");
  }
  const apng = metadata.format === "png" ? readApngTiming(bytes) : null;
  const frameCount = apng?.frameCount ?? metadata.pages ?? 1;
  const frameHeight = metadata.pageHeight ?? metadata.height;
  if (!metadata.width || !frameHeight) throw new ApiError(422, "INVALID_IMAGE", "The image has no dimensions");
  // Not a limit — a file whose `acTL` claims zero frames is malformed, not merely large.
  if (frameCount < 1) throw new ApiError(422, "INVALID_IMAGE", "The image declares no frames");
  if (metadata.width * frameHeight > MAX_FRAME_PIXELS) {
    throw new ApiError(422, "IMAGE_DECODE_TOO_LARGE", "The decoded image exceeds the safe pixel limit");
  }
  try {
    // Metadata above verifies the complete animation's dimensions, frame count, and timing. Pixel
    // stats only need to prove that the rendition contains transparency and painted pixels. Asking
    // libvips for animated stats stacks every GIF frame into one enormous image; a valid 150-frame
    // 1024px export becomes ~157 million decoded pixels and can exhaust a production worker. Decode
    // one composited frame instead, bounded by the already-verified per-frame dimensions.
    stats = await sharp(bytes, {
      page: 0,
      pages: 1,
      limitInputPixels: metadata.width * frameHeight,
    }).stats();
  } catch {
    throw new ApiError(422, "INVALID_IMAGE", "The image pixels could not be decoded safely");
  }
  const alpha = stats.channels.length > 3 ? stats.channels[3] : undefined;
  // sharp only pages formats libvips can animate, so an APNG's timing comes from its own chunks.
  const durationSeconds = apng?.durationSeconds
    ?? (frameCount > 1 && metadata.delay?.length
      ? metadata.delay.reduce((total, delay) => total + delay, 0) / 1000
      : 0);
  return {
    width: metadata.width,
    height: frameHeight,
    mimeType: formatToMime(metadata.format),
    hasAlpha: Boolean(metadata.hasAlpha),
    hasTransparentPixels: Boolean(metadata.hasAlpha && alpha && alpha.min < 255),
    hasNonTransparentPixels: Boolean(metadata.hasAlpha && alpha && alpha.max > 0),
    frameCount,
    durationSeconds,
    fps: durationSeconds > 0 ? frameCount / durationSeconds : 0,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    byteSize: bytes.byteLength,
  };
}

/**
 * Squares a generated image up to the 1024x1024 frame every layer is drawn from.
 *
 * With `subjectCrop` the frame is first cut down to its visible artwork, so the layer box a
 * document places it in describes the pixels rather than whatever margin the model left around
 * them. `subject` is measured in the *source* frame, before the crop, which is what lets a part
 * separated from a reference say where in that reference it was.
 */
export async function normalizeTransparentPng(
  bytes: Uint8Array,
  options: { subjectCrop?: boolean } = {},
): Promise<{ bytes: Uint8Array; inspection: ImageInspection; subject?: SubjectBounds }> {
  const cropped = options.subjectCrop ? await cropPngToSubject(bytes) : { bytes };
  const png = await sharp(cropped.bytes, { limitInputPixels: 4096 * 4096 })
    .resize(1024, 1024, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return { bytes: png, inspection: await inspectImage(png), subject: cropped.subject };
}

/**
 * The longest edge an image keeps when it is handed to a reasoning model to look at.
 *
 * A vision model tiles a square image at roughly this size anyway, so anything larger is paid for
 * and then discarded. It also has to stay large enough to read a frame atlas as a contact sheet: a
 * 4x4 capture leaves each frame around 256px, which is plenty to see what the subject does.
 */
const MODEL_INPUT_MAX_EDGE = 1024;

/**
 * Shrinks an attachment into something an agent can be shown cheaply on every step of a tool loop.
 *
 * Two choices worth stating. It is flattened onto white rather than kept transparent, because a
 * cut-out subject on an alpha background is composited onto black by most providers, which is
 * exactly where a dark subject disappears. And it is re-encoded as JPEG, because the agent judges
 * what is in the picture rather than the quality of its edges, and a downscaled photograph as PNG
 * is several times the bytes for nothing.
 *
 * Only the first frame of an animated attachment survives — the frames of a capture already arrive
 * as one atlas, so there is nothing here worth paging through.
 */
export async function downscaleForModelInput(
  bytes: Uint8Array,
): Promise<{ bytes: Uint8Array; mimeType: "image/jpeg" }> {
  const jpeg = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .resize(MODEL_INPUT_MAX_EDGE, MODEL_INPUT_MAX_EDGE, {
      fit: "inside",
      withoutEnlargement: true,
    })
    .flatten({ background: "#ffffff" })
    .jpeg({ quality: 80 })
    .toBuffer();
  return { bytes: new Uint8Array(jpeg), mimeType: "image/jpeg" };
}

export function objectKey(ownerId: string, assetId: string, mimeType: string): string {
  const extension = ({
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/webp": "webp",
    "image/gif": "gif",
    "video/mp4": "mp4",
    "video/webm": "webm",
  } as Record<string, string>)[mimeType] ?? "bin";
  const safeOwner = createHash("sha256").update(ownerId).digest("hex").slice(0, 24);
  return `private/${safeOwner}/${assetId}.${extension}`;
}
