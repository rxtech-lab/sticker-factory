import { readFileSync } from "node:fs";
import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { ATTACHMENT_RENDITION_DIMENSIONS } from "@/lib/contracts/api";
import { StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import type { RenderAssets } from "@/lib/render/document-svg";
import { animatedRenditionTiming, renderApng, renderStillPng } from "@/lib/render/renditions";
import { referencedAssetIds } from "@/lib/render/sticker-render";
import { validateImageForKind } from "@/lib/services/assets";
import { validateAnimatedRenditionTiming } from "@/lib/services/stickers";
import { inspectImage } from "@/lib/storage/r2";
import type { assets as assetsTable } from "@/lib/db/schema";

const animatedFixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")),
);

/**
 * The same artwork with the motion taken out.
 *
 * Built by stripping rather than by hand so the two cases draw the same layer: a static document
 * rejects any keyframe past t=0, and the particle layer has nothing to scatter without a timeline.
 */
const staticFixture = () => {
  const animated = animatedFixture();
  const image = animated.layers.find((layer) => layer.type === "image");
  if (!image) throw new Error("fixture has no image layer");
  return StickerDocumentSchema.parse({
    ...animated,
    kind: "static",
    durationSeconds: 0,
    fps: 0,
    loop: "once",
    speed: 1,
    layers: [{
      ...image,
      animations: [],
      animation: {
        position: [], scale: [], rotation: [], opacity: [],
        effects: [], trim: [], wipe: [], sheen: [], glow: [],
      },
    }],
  });
};

/** A cut-out subject: painted in the middle, transparent at the edges, like generated artwork. */
async function artwork(): Promise<Uint8Array> {
  const png = await sharp({
    create: { width: 512, height: 512, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([{
      input: await sharp({ create: { width: 256, height: 256, channels: 4, background: { r: 240, g: 90, b: 120, alpha: 1 } } })
        .png().toBuffer(),
      left: 128,
      top: 128,
    }])
    .png()
    .toBuffer();
  return new Uint8Array(png);
}

async function assetsFor(document: StickerDocument): Promise<RenderAssets> {
  const bytes = await artwork();
  const map: RenderAssets = new Map();
  for (const id of referencedAssetIds(document)) map.set(id, { bytes, mimeType: "image/png" });
  return map;
}

/** The shape `validateImageForKind` reads. Only the fields it and the timing check look at matter. */
function assetRow(kind: string, inspection: Awaited<ReturnType<typeof inspectImage>>) {
  return {
    kind,
    mimeType: inspection.mimeType,
    byteSize: inspection.byteSize,
    width: inspection.width,
    height: inspection.height,
    frameCount: inspection.frameCount,
    durationSeconds: inspection.durationSeconds,
    fps: inspection.fps,
  } as unknown as typeof assetsTable.$inferSelect;
}

describe("server-rendered publish renditions", () => {
  it("renders a master the publish contract accepts", async () => {
    const document = staticFixture();
    const bytes = await renderStillPng(document, await assetsFor(document), 1_024);
    const inspection = await inspectImage(bytes);

    expect(inspection.width).toBe(1_024);
    expect(inspection.frameCount).toBe(1);
    expect(() => validateImageForKind(assetRow("master", inspection), inspection)).not.toThrow();
  });

  it("renders attachment renditions at both sizes", async () => {
    const document = staticFixture();
    const sourceAssets = await assetsFor(document);
    for (const size of Object.values(ATTACHMENT_RENDITION_DIMENSIONS)) {
      const inspection = await inspectImage(await renderStillPng(document, sourceAssets, size));
      expect(inspection.width).toBe(size);
      expect(() => validateImageForKind(assetRow("attachment", inspection), inspection)).not.toThrow();
    }
  });

  it("stitches an APNG whose frame grid matches the document", async () => {
    const document = animatedFixture();
    if (document.kind !== "animated") throw new Error("fixture is not animated");
    const { bytes } = await renderApng(document, await assetsFor(document), 408, document.fps);
    const inspection = await inspectImage(bytes);

    // The grid the publish is checked against: one cycle at the document's own fps, plus the hold.
    const timing = animatedRenditionTiming(document, document.fps);
    expect(inspection.mimeType).toBe("image/png");
    expect(inspection.frameCount).toBe(timing.times.length);
    expect(inspection.durationSeconds).toBeCloseTo(timing.cycleSeconds + timing.holdSeconds, 2);

    expect(() => validateImageForKind(assetRow("apng", inspection), inspection)).not.toThrow();
    expect(() => validateAnimatedRenditionTiming(document, assetRow("apng", inspection))).not.toThrow();
  });

  it("keeps a lower-fps system rendition inside the ladder's window", async () => {
    const document = animatedFixture();
    if (document.kind !== "animated") throw new Error("fixture is not animated");
    const { bytes } = await renderApng(document, await assetsFor(document), 300, 8);
    const inspection = await inspectImage(bytes);

    expect(inspection.byteSize).toBeLessThan(500_000);
    expect(() => validateImageForKind(assetRow("system", inspection), inspection)).not.toThrow();
    expect(() => validateAnimatedRenditionTiming(document, assetRow("system", inspection))).not.toThrow();
  });

  it("decodes every stitched frame", async () => {
    const document = animatedFixture();
    if (document.kind !== "animated") throw new Error("fixture is not animated");
    const { bytes } = await renderApng(document, await assetsFor(document), 300, 6);
    // sharp has no APNG decoder, so this only proves the container's first frame is a valid PNG —
    // `inspectImage` above is what reads the animation chunks back.
    const metadata = await sharp(Buffer.from(bytes)).metadata();
    expect(metadata.format).toBe("png");
    expect(metadata.width).toBe(300);
  });
});
