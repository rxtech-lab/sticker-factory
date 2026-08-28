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
import { ApiError } from "@/lib/http/errors";

export interface StoredObject {
  bytes: Uint8Array;
  contentType: string;
  metadata?: Record<string, string>;
}

export interface ObjectStore {
  signedPut(key: string, contentType: string, byteSize: number): Promise<{ url: string; expiresAt: Date; headers: Record<string, string> }>;
  signedGet(key: string, filename?: string): Promise<{ url: string; expiresAt: Date }>;
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

  async signedGet(key: string, filename?: string) {
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000);
    const safeFilename = filename?.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120) || "sticker";
    const command = new GetObjectCommand({
      Bucket: this.bucket,
      Key: key,
      ...(filename ? { ResponseContentDisposition: `attachment; filename="${safeFilename}"` } : {}),
    });
    return { url: await getSignedUrl(this.client, command, { expiresIn: 300 }), expiresAt };
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
  async signedGet(key: string, filename?: string) {
    if (!this.objects.has(key) && process.env.STICKER_FACTORY_E2E !== "true") {
      throw new ApiError(404, "ASSET_OBJECT_MISSING", "The media object does not exist");
    }
    return {
      url: filename
        ? `https://downloads.invalid/${encodeURIComponent(key)}?disposition=${encodeURIComponent(`attachment; filename="${filename}"`)}`
        : `https://downloads.invalid/${encodeURIComponent(key)}?mode=inline`,
      expiresAt: new Date(Date.now() + 300_000),
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
  if (timing.durationSeconds < 0.5 || timing.durationSeconds > 8 || timing.fps > 30.01) {
    throw new ApiError(422, "INVALID_MP4_TIMING", "MP4 exports must be 0.5–8 seconds at no more than 30 FPS");
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
  if (frameCount < 1 || frameCount > 240) throw new ApiError(422, "TOO_MANY_IMAGE_FRAMES", "Animated images may contain at most 240 frames");
  const totalPixels = metadata.width * frameHeight * frameCount;
  const maximumPixels = frameCount > 1 ? 1024 * 1024 * 240 : 4096 * 4096;
  if (totalPixels > maximumPixels) throw new ApiError(422, "IMAGE_DECODE_TOO_LARGE", "The decoded image exceeds the safe pixel limit");
  try {
    stats = await sharp(bytes, { animated: true, limitInputPixels: maximumPixels }).stats();
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

export async function normalizeTransparentPng(bytes: Uint8Array): Promise<{ bytes: Uint8Array; inspection: ImageInspection }> {
  const png = await sharp(bytes, { limitInputPixels: 4096 * 4096 })
    .resize(1024, 1024, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return { bytes: png, inspection: await inspectImage(png) };
}

export function objectKey(ownerId: string, assetId: string, mimeType: string): string {
  const extension = ({
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/webp": "webp",
    "image/gif": "gif",
    "video/mp4": "mp4",
  } as Record<string, string>)[mimeType] ?? "bin";
  const safeOwner = createHash("sha256").update(ownerId).digest("hex").slice(0, 24);
  return `private/${safeOwner}/${assetId}.${extension}`;
}
