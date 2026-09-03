import { randomFillSync } from "node:crypto";
import { readFileSync } from "node:fs";
import sharp from "sharp";
import { describe, expect, it } from "vitest";
import { sampleLayerState, loopedTime } from "@/lib/animation/sample";
import { applyStickerOperationsV1, StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { documentSvg, prepareSheetAssets, referencedAssetIds, renderSticker } from "@/lib/render/sticker-render";
import { shapeGeometry } from "@/lib/render/shapes";

const fixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")),
);

/** The v3 fixture, which is the one carrying a `sequence` layer. */
const captureFixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v3.json", "utf8")),
);

/** The v4 fixture, which is the one carrying a `video` layer. */
const clipFixture = () => StickerDocumentSchema.parse(
  JSON.parse(readFileSync("fixtures/sticker-document-v4.json", "utf8")),
);

/**
 * A frame atlas as heavy as the iOS encoder is allowed to ship one.
 *
 * Incompressible on purpose: `FrameAtlasEncoder` packs up to 64 tiles at 640px and only steps down
 * when the PNG passes 20 MB, so a photographic capture lands in exactly this territory.
 */
async function captureAtlas(tile: number, columns: number, rows: number): Promise<Uint8Array> {
  const width = tile * columns;
  const height = tile * rows;
  const raw = Buffer.alloc(width * height * 4);
  randomFillSync(raw);
  for (let index = 3; index < raw.length; index += 4) raw[index] = 255;
  const png = await sharp(raw, { raw: { width, height, channels: 4 } }).png().toBuffer();
  return new Uint8Array(png);
}

/**
 * RIFF....WEBP. A `sharp` failure would hand back something else, or throw.
 *
 * The sheet is WebP rather than PNG because it is fed into the model's context on every
 * `view_sticker` call, where its byte size is a cost paid over and over.
 */
function isWebp(bytes: Uint8Array): boolean {
  const header = Buffer.from(bytes.slice(0, 12));
  return header.subarray(0, 4).toString("ascii") === "RIFF"
    && header.subarray(8, 12).toString("ascii") === "WEBP";
}

function withShape(base: StickerDocument, id: string, shape: unknown, animations: unknown[] = []): StickerDocument {
  return applyStickerOperationsV1(base, [
    {
      op: "addLayer",
      layer: {
        id,
        name: id,
        hidden: false,
        anchor: {
          position: { x: 0.5, y: 0.5 },
          scale: { x: 0.4, y: 0.4 },
          rotationDegrees: 0,
          opacity: 1,
          trim: { start: 0, end: 1 },
        },
        blendMode: "normal",
        type: "shape",
        shape,
        fill: { type: "solid", color: "#FFD166" },
        cornerRadius: 0.12,
        animations: [],
        animation: {
          position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
        },
      },
    } as never,
    ...(animations.length > 0
      ? [{ op: "setLayerAnimations", layerId: id, animations } as never]
      : []),
  ]);
}

describe("shape geometry", () => {
  it("emits a closed path for every parameterised kind", () => {
    const kinds = [
      { kind: "triangle" }, { kind: "heart" }, { kind: "burst" },
      { kind: "star", points: 5, innerRatio: 0.42 }, { kind: "polygon", sides: 6 },
    ] as const;
    for (const kind of kinds) {
      const geometry = shapeGeometry(kind, 0.12);
      expect(geometry.kind, kind.kind).toBe("path");
      if (geometry.kind !== "path") continue;
      expect(geometry.d.startsWith("M"), kind.kind).toBe(true);
      expect(geometry.d.endsWith("Z"), kind.kind).toBe(true);
      // Everything must land inside the unit box, or a shape would spill past its own layer.
      for (const value of geometry.d.match(/-?\d+\.?\d*/g) ?? []) {
        expect(Number(value)).toBeGreaterThanOrEqual(-0.001);
        expect(Number(value)).toBeLessThanOrEqual(1.001);
      }
    }
  });

  it("keeps circles and rounded rectangles as primitives", () => {
    // Rounding a rect through path data would approximate what SVG can do exactly.
    expect(shapeGeometry({ kind: "circle" }, 0.12).kind).toBe("ellipse");
    expect(shapeGeometry({ kind: "roundedRectangle" }, 0.2)).toEqual({ kind: "rect", cornerRadius: 0.2 });
    expect(shapeGeometry({ kind: "capsule" }, 0.12)).toEqual({ kind: "rect", cornerRadius: 0.5 });
  });

  it("passes author path data through untouched", () => {
    const geometry = shapeGeometry({ kind: "path", d: "M0,0 L1,1" }, 0.12);
    expect(geometry).toEqual({ kind: "path", d: "M0,0 L1,1" });
  });
});

describe("sampling", () => {
  it("resolves an empty channel to the layer's anchor rather than to zero", () => {
    const base = fixture();
    const layer = base.layers[0];
    const state = sampleLayerState(layer, 0);
    expect(state.position).toEqual(layer.anchor.position);
    expect(state.opacity).toBe(layer.anchor.opacity);
  });

  it("reads a wipe as closed at its start and open at its end", () => {
    const document = withShape(fixture(), "wiped", { kind: "circle" }, [
      { type: "wipeIn", direction: "right", duration: 1, easing: "linear" },
    ]);
    const layer = document.layers.find((item) => item.id === "wiped")!;
    expect(sampleLayerState(layer, 0).wipe.end).toBe(0);
    expect(sampleLayerState(layer, 1).wipe.end).toBe(1);
    // Half way through a linear wipe the window is half open — this is the value the mask renders.
    expect(sampleLayerState(layer, 0.5).wipe.end).toBeCloseTo(0.5, 5);
  });

  it("wraps a looping timeline and folds a ping-pong one back", () => {
    expect(loopedTime(2.5, { durationSeconds: 2, loop: "loop" })).toBeCloseTo(0.5, 5);
    expect(loopedTime(2.5, { durationSeconds: 2, loop: "pingPong" })).toBeCloseTo(1.5, 5);
    expect(loopedTime(9, { durationSeconds: 2, loop: "once" })).toBe(2);
  });
});

describe("referenced assets", () => {
  it("collects artwork, masks, svg sources and the background", () => {
    const base = fixture();
    const ids = referencedAssetIds(base);
    const imageLayer = base.layers.find((layer) => layer.type === "image");
    expect(imageLayer).toBeDefined();
    if (imageLayer?.type === "image") expect(ids).toContain(imageLayer.assetId);
  });

  it("returns nothing for a document that draws itself", () => {
    const document = withShape(
      { ...fixture(), layers: [] } as StickerDocument,
      "solo",
      { kind: "star", points: 5, innerRatio: 0.4 },
    );
    expect(referencedAssetIds(document)).toEqual([]);
  });

  it("asks for a video layer's poster and never for its clip", () => {
    const document = clipFixture();
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the fixture's hero layer is not a video");
    const ids = referencedAssetIds(document);
    expect(ids).toContain(hero.posterAssetId);
    expect(ids).not.toContain(hero.assetId);
  });
});

describe("video layers", () => {
  it("draws the poster still in place of the clip", async () => {
    const document = clipFixture();
    const hero = document.layers[0];
    if (hero.type !== "video") throw new Error("the fixture's hero layer is not a video");
    const poster = new Uint8Array(await sharp({
      create: { width: 8, height: 8, channels: 4, background: { r: 200, g: 40, b: 40, alpha: 1 } },
    }).png().toBuffer());
    const { svg } = documentSvg(document, new Map([[hero.posterAssetId, { bytes: poster, mimeType: "image/png" }]]));
    expect(svg).toContain(`data:image/png;base64,${Buffer.from(poster).toString("base64")}`);
    expect(svg).not.toContain("video/mp4");
  });

  it("draws a placeholder for a poster it could not load instead of dropping the layer", () => {
    const { svg } = documentSvg(clipFixture(), new Map());
    expect(svg).toContain(">video<");
  });
});

describe("rendering", () => {
  it("draws a contact sheet for an animated document", async () => {
    const render = await renderSticker(fixture(), new Map());
    expect(render.times.length).toBeGreaterThan(1);
    expect(isWebp(render.bytes)).toBe(true);
    expect(render.mimeType).toBe("image/webp");
    // Every sampled instant must sit inside the authored timeline, or a tile would be blank.
    for (const time of render.times) {
      expect(time).toBeGreaterThanOrEqual(0);
      expect(time).toBeLessThanOrEqual(fixture().durationSeconds);
    }
  });

  it("draws a single frame for a static document", async () => {
    const animated = fixture();
    // A static document is its own variant, not the animated one with the motion removed: duration,
    // fps, loop and speed are all pinned literals, and it may carry no keyframes at all.
    const staticDocument = StickerDocumentSchema.parse({
      version: animated.version,
      canvas: animated.canvas,
      background: animated.background,
      mp4Background: animated.mp4Background,
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      speed: 1,
      layers: animated.layers.map((layer) => ({
        ...layer,
        animations: [],
        animation: {
          position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
        },
      })),
    });
    const render = await renderSticker(staticDocument, new Map());
    expect(render.times).toEqual([0]);
    expect(render.width).toBe(render.height - 22);
  });

  it("stays small enough to hand back through the model's context", async () => {
    // The render is fed into the message history, where `estimateTokens` stringifies it. A sheet
    // that grew into the hundreds of kilobytes would trip compaction and start pruning tool calls.
    const render = await renderSticker(fixture(), new Map());
    expect(render.bytes.byteLength).toBeLessThan(200_000);
  });

  it("renders a capture atlas far too large to inline", async () => {
    // The bug this pins: every bitmap is inlined as a base64 `data:` URI, once per tile, and
    // libxml2 rejects any single attribute over 10 MB. A real Live Photo atlas is several times
    // that, so `view_sticker` failed on every animated sticker built from one — the render came
    // back as "Buffer size limit exceeded, try XML_PARSE_HUGE" rather than as pixels.
    const document = captureFixture();
    const layer = document.layers.find((item) => item.type === "sequence");
    expect(layer?.type).toBe("sequence");
    if (layer?.type !== "sequence") return;

    const bytes = await captureAtlas(640, layer.columns, layer.rows);
    expect(bytes.byteLength).toBeGreaterThan(10_000_000);
    const render = await renderSticker(document, new Map([[layer.assetId, { bytes, mimeType: "image/png" }]]));
    expect(isWebp(render.bytes)).toBe(true);
  }, 60_000);

  it("inlines one cell per tile rather than the whole atlas", async () => {
    // The fix the test above only proves the *symptom* of. A sheet that draws six frames must carry
    // six frames, not six copies of every frame — the difference between a few hundred kilobytes of
    // markup and tens of megabytes, and the reason the 10 MB attribute ceiling was ever in reach.
    const document = captureFixture();
    const layer = document.layers.find((item) => item.type === "sequence");
    if (layer?.type !== "sequence") return;

    const bytes = await captureAtlas(640, layer.columns, layer.rows);
    const assets = new Map([[layer.assetId, { bytes, mimeType: "image/png" }]]);
    const { svg } = documentSvg(document, await prepareSheetAssets(document, assets));

    const hrefs = [...svg.matchAll(/href="data:[^"]*"/g)].map((match) => match[0].length);
    expect(hrefs.length).toBeGreaterThan(0);
    // Bounds sized against this fixture, whose atlas is incompressible noise on purpose and so is
    // the worst case a real capture can approach. Measured: 205 KB and 1.24 MB, against 2.45 MB and
    // 14.74 MB before — so these fail long before the 10 MB attribute ceiling is back in reach.
    expect(Math.max(...hrefs)).toBeLessThan(400_000);
    expect(svg.length).toBeLessThan(2_000_000);
    // The atlas itself must be gone from the prepared map, or the whole-atlas fallback would still
    // be reachable and the saving would silently depend on which branch `layerBody` took.
    expect((await prepareSheetAssets(document, assets)).has(layer.assetId)).toBe(false);
  }, 60_000);

  it("cuts the cell the playing client would show", async () => {
    // Each cell is filled with a distinct solid colour, so the wrong crop is not a subtle
    // difference — it is the wrong hue entirely. Pins the floor division against the renderer's.
    const document = captureFixture();
    const layer = document.layers.find((item) => item.type === "sequence");
    if (layer?.type !== "sequence") return;

    const cell = 64;
    const composites = [];
    for (let index = 0; index < layer.columns * layer.rows; index += 1) {
      const hue = Math.round((index / (layer.columns * layer.rows)) * 360);
      composites.push({
        input: {
          create: { width: cell, height: cell, channels: 4 as const, background: `hsl(${hue}, 90%, 50%)` },
        },
        left: (index % layer.columns) * cell,
        top: Math.floor(index / layer.columns) * cell,
      });
    }
    const atlas = await sharp({
      create: {
        width: cell * layer.columns, height: cell * layer.rows,
        channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 },
      },
    }).composite(composites).png().toBuffer();

    const prepared = await prepareSheetAssets(
      document,
      new Map([[layer.assetId, { bytes: new Uint8Array(atlas), mimeType: "image/png" }]]),
    );
    // Frame 0 is the top-left cell, which is hue 0 — pure red.
    const zero = prepared.get(`${layer.assetId}#0`);
    expect(zero).toBeDefined();
    const pixel = await sharp(zero!.bytes).resize(1, 1, { fit: "fill" }).raw().toBuffer();
    expect(pixel[0]).toBeGreaterThan(200);
    expect(pixel[1]).toBeLessThan(60);
    expect(pixel[2]).toBeLessThan(60);

    // And the same colour has to survive all the way onto the finished sheet. This is the guard
    // that matters: librsvg does not error on an embedded format it cannot decode, it draws
    // nothing — so a bad encoding choice for the inlined cells would show up as a blank tile the
    // agent cannot tell from an empty layer, and every assertion above would still pass.
    const render = await renderSticker(document, new Map([[layer.assetId, {
      bytes: new Uint8Array(atlas), mimeType: "image/png",
    }]]));
    const { data, info } = await sharp(render.bytes).raw().toBuffer({ resolveWithObject: true });
    let saturated = 0;
    for (let offset = 0; offset < data.length; offset += info.channels) {
      if (data[offset] > 150 && data[offset + 1] < 90 && data[offset + 2] < 90) saturated += 1;
    }
    expect(saturated).toBeGreaterThan(100);
  }, 60_000);

  it("draws a placeholder for artwork it could not load instead of dropping the layer", () => {
    const { svg } = documentSvg(fixture(), new Map());
    expect(svg).toContain("artwork");
  });

  it("produces well-formed markup with balanced defs", () => {
    const document = withShape(fixture(), "wiped", { kind: "heart" }, [
      { type: "wipeIn", direction: "up", softness: 0.2, duration: 1 },
      { type: "shine", width: 0.3, intensity: 0.8, delay: 1, duration: 1 },
    ]);
    const { svg } = documentSvg(document, new Map());
    expect(svg.startsWith("<svg")).toBe(true);
    expect(svg.endsWith("</svg>")).toBe(true);
    expect(svg).toContain("<mask");
    expect(svg).toContain("linearGradient");
    // Ids must be unique, or one layer's gradient would silently paint another's.
    const ids = [...svg.matchAll(/ id="([^"]+)"/g)].map((match) => match[1]);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("escapes text so a layer cannot break the document", () => {
    const document = applyStickerOperationsV1(fixture(), [
      {
        op: "addLayer",
        layer: {
          id: "hostile",
          name: "Hostile",
          hidden: false,
          anchor: {
            position: { x: 0.5, y: 0.5 }, scale: { x: 0.5, y: 0.5 },
            rotationDegrees: 0, opacity: 1, trim: { start: 0, end: 1 },
          },
          blendMode: "normal",
          type: "text",
          text: '</text><script>x</script>',
          font: "system",
          weight: "bold",
          paint: { type: "solid", color: "#FFFFFF" },
          alignment: "center",
          animations: [],
          animation: {
            position: [], scale: [], rotation: [], opacity: [], effects: [], trim: [], wipe: [], sheen: [], glow: [],
          },
        },
      } as never,
    ]);
    const { svg } = documentSvg(document, new Map());
    expect(svg).not.toContain("<script>");
    expect(svg).toContain("&lt;script&gt;");
  });
});

describe("layer scale in the render", () => {
  // The native renderer fits glyphs inside their box; the reviewer's render has to show the same
  // square of letters, or the model corrects a stretch that only its own picture had.
  it("squares a text layer's unequal scale the way the native renderer does", () => {
    const document = applyStickerOperationsV1(fixture(), [{
      op: "addLayer",
      layer: {
        id: "caption", name: "Caption", hidden: false, type: "text", text: "HI",
        font: "rounded", weight: "bold", paint: { type: "solid", color: "#FF0055" },
        anchor: {
          position: { x: 0.5, y: 0.5 }, scale: { x: 0.9, y: 0.35 }, rotationDegrees: 0, opacity: 1,
          trim: { start: 0, end: 1 },
        },
      },
    }] as Parameters<typeof applyStickerOperationsV1>[1]);
    const { svg } = documentSvg(document, new Map());
    expect(svg).toContain("scale(0.35,0.35)");
    expect(svg).not.toContain("scale(0.9,0.35)");
  });

  it("leaves a shape free to stretch", () => {
    const document = withShape(fixture(), "banner", { kind: "roundedRectangle" });
    const banner = document.layers.find((layer) => layer.id === "banner")!;
    const stretched = applyStickerOperationsV1(document, [{
      op: "setLayerAnimations",
      layerId: "banner",
      animations: [],
      anchor: { ...banner.anchor, scale: { x: 0.9, y: 0.35 } },
    }]);
    expect(documentSvg(stretched, new Map()).svg).toContain("scale(0.9,0.35)");
  });
});
