import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiImageInput, type AiImageOutput } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { documentRenderableLayers, layerImageAssetIds, resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatThreads, generationJobs } from "@/lib/db/schema";
import { renderSticker } from "@/lib/render/sticker-render";
import { validateDocumentAssetReferences } from "@/lib/services/sticker-documents";
import { MemoryObjectStore, inspectImage, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { documentFromPlan } from "@/workflows/sticker-generation/asset-generation";
import { generateSpriteArtwork, spriteClipAssetIds } from "@/workflows/sticker-generation/sprite-artwork";

afterEach(() => { setDatabaseForTests(undefined); setAiProviderForTests(undefined); setObjectStoreForTests(undefined); });

it("draws one sheet per clip and one of faces, registers the slots, and replays for free", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    const store = new MemoryObjectStore(); setObjectStoreForTests(store);
    await seedUser(db, "owner");
    const sticker = await seedPublishedSticker(db, "owner", { kind: "animated" });
    await db.insert(chatThreads).values({ id: crypto.randomUUID(), stickerId: sticker.stickerId, ownerId: "owner" });
    const [job] = await db.insert(generationJobs).values({ id: crypto.randomUUID(), stickerId: sticker.stickerId, ownerId: "owner", kind: "compose", state: "running" }).returning();
    const tile = await sharp({ create: { width: 256, height: 256, channels: 4, background: "red" } }).png().toBuffer();
    const blank = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer();
    const approved = await sharp(blank).composite([{ input: tile, left: 384, top: 384 }]).png().toBuffer();

    const requests: AiImageInput[] = [];
    let failedOnce = false;
    class Provider extends MockAiProvider {
      override async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
        requests.push(input);
        // The first clip sheet comes back without a face placeholder, which registration must refuse.
        if (input.sheet?.facePlaceholder && !failedOnce) {
          failedOnce = true;
          return super.generateStickerImage({ ...input, sheet: { ...input.sheet, facePlaceholder: false } });
        }
        return super.generateStickerImage(input);
      }
    }
    setAiProviderForTests(new Provider());

    const plan = PlanV1Schema.parse({ title: "Cat", summary: "A cat with moods and poses", kind: "animated", timing: { durationSeconds: 3, fps: 24, loop: "loop" },
      layers: [{ layerId: "hero", name: "Cat", x: 0.5, y: 0.5, scaleX: 1, scaleY: 1, source: {
        kind: "sprite", prompt: "A round orange cat",
        clips: [
          { id: "idle", label: "Idle", prompt: "breathes and blinks", frames: [{ duration: 2.4 }, { duration: 0.18 }, { duration: 0.28 }, { duration: 0.22 }, { duration: 0.3 }, { duration: 1.2 }] },
          { id: "wave", label: "Wave", prompt: "raises a paw", frames: [{ duration: 0.4 }, { duration: 0.3 }, { duration: 0.35 }, { duration: 0.3 }] },
        ],
        expressions: [{ id: "neutral", label: "Neutral", prompt: "calm" }, { id: "happy", label: "Happy", prompt: "smiling" }, { id: "sad", label: "Sad", prompt: "downturned" }],
      } }],
      configuration: { controls: [
        { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }, { id: "sad", label: "Sad" }] },
        { id: "pose", type: "choice", label: "Pose", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "wave", label: "Wave" }] },
      ], variants: [
        { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
        { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
        { id: "sad", selections: { mood: "sad" }, layers: [{ layerId: "hero", expression: "sad" }] },
        { id: "idle", selections: { pose: "idle" }, layers: [{ layerId: "hero", clip: "idle" }] },
        { id: "wave", selections: { pose: "wave" }, layers: [{ layerId: "hero", clip: "wave" }] },
      ] } });

    // The still is separated by the ordinary part loop; here it is seeded directly.
    const stillId = "00000000-0000-4000-8000-000000000001";
    const { generatedLayers } = await import("@/workflows/sticker-generation/asset-generation");
    const separated = generatedLayers(plan, job.id)[0].assetId;
    void stillId;
    const inspection = await inspectImage(approved);
    const r2Key = objectKey("owner", separated, "image/png");
    await store.put(r2Key, { bytes: approved, contentType: "image/png" });
    await db.insert(assets).values({ id: separated, ownerId: "owner", stickerId: sticker.stickerId, kind: "master", state: "ready", r2Key,
      mimeType: "image/png", byteSize: approved.length, width: 1024, height: 1024, sha256: inspection.sha256, hasAlpha: true });
    const reference = { bytes: approved, mimeType: "image/png" };

    await expect(generateSpriteArtwork(job, sticker.stickerId, plan, job.id, reference)).rejects.toThrow("frame 1 has no face placeholder");
    const rawIdle = spriteClipAssetIds(job.id, "hero", "idle").raw;
    expect((await db.select().from(assets).where(eq(assets.id, rawIdle)))[0].state).toBe("failed");

    const builds = await generateSpriteArtwork(job, sticker.stickerId, plan, job.id, reference);
    // One failed idle sheet, then idle again, wave, and the expression sheet.
    expect(requests).toHaveLength(4);
    for (const request of requests) {
      expect(request.keepFrame).toBe(true);
      expect(request.quality).toBe("medium");
      expect(request.references).toHaveLength(request.sheet?.tiles ? 3 : 2);
      expect(request.sheet).toBeDefined();
    }
    expect(requests[1].sheet).toMatchObject({ columns: 3, rows: 2, count: 6, facePlaceholder: true });
    expect(requests[2].sheet).toMatchObject({ columns: 3, rows: 2, count: 4, facePlaceholder: true });
    expect(requests[3].sheet).toMatchObject({ columns: 2, rows: 2, count: 3, tiles: true });
    expect(requests[3].prompt).toContain("1. Neutral: calm");
    expect(requests[3].prompt).toContain("last reference");
    expect(requests[3].prompt).toContain("Do not draw a second head");
    // Expressions must see the actual opening they will fill, not only full-character references.
    // Keep the raw frame's magenta marker: the cleaned body no longer identifies that opening.
    const rawSheet = (await store.get(objectKey("owner", rawIdle, "image/png"))).bytes;
    const rawMeta = await sharp(rawSheet).metadata();
    const firstFrame = await sharp(rawSheet).extract({ left: 0, top: 0,
      width: Math.floor(rawMeta.width! / 3), height: Math.floor(rawMeta.height! / 2),
    }).ensureAlpha().raw().toBuffer();
    const guide = requests[3].references[2];
    expect(guide.mimeType).toBe("image/png");
    expect(await sharp(guide.bytes).ensureAlpha().raw().toBuffer()).toEqual(firstFrame);

    const build = builds.get("hero")!;
    expect(build.clips.map((clip) => clip.frames.length)).toEqual([6, 4]);
    for (const frame of build.clips.flatMap((clip) => clip.frames)) {
      expect(frame.faceX).toBeGreaterThan(0.3); expect(frame.faceX).toBeLessThan(0.7);
      expect(frame.faceSize).toBeGreaterThan(0.1);
    }
    expect(build.expressions.tiles.map((tile) => tile.id)).toEqual(["neutral", "happy", "sad"]);

    const document = documentFromPlan(plan, job.id, new Map(), builds);
    expect(document.layers[0]).toMatchObject({ type: "sprite", clipId: "idle", expressionId: "neutral", posterAssetId: build.posterAssetId });
    expect(document.durationSeconds).toBeCloseTo(4.58, 5);
    await expect(validateDocumentAssetReferences(db, "owner", sticker.stickerId, document)).resolves.toBeInstanceOf(Map);
    const stored = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    const byId = new Map(stored.map((asset) => [asset.id, asset]));
    // The painted-out clip sheets and the expression sheet carry their grids like a capture atlas.
    expect(build.clips.map((clip) => byId.get(clip.assetId)!).map((asset) => [asset.kind, asset.state, asset.frameCount, asset.sequenceColumns, asset.sequenceRows]))
      .toEqual([["sequence", "ready", 6, 3, 2], ["sequence", "ready", 4, 3, 2]]);
    expect(byId.get(build.expressions.assetId)).toMatchObject({ kind: "sequence", state: "ready", frameCount: 3, sequenceColumns: 2, sequenceRows: 2 });
    const poster = stored.find((asset) => asset.id === build.posterAssetId)!;
    expect([poster.width, poster.height, poster.hasAlpha]).toEqual([1024, 1024, true]);

    // A replay measures the stored sheets again and buys nothing.
    const again = await generateSpriteArtwork(job, sticker.stickerId, plan, job.id, reference);
    expect(requests).toHaveLength(4);
    expect(again.get("hero")).toEqual(build);

    // The review render composites the selected face into the selected clip's frames.
    const assetBytes = new Map<string, { bytes: Uint8Array; mimeType: string }>();
    for (const layer of documentRenderableLayers(document)) for (const id of layerImageAssetIds(layer)) {
      const row = stored.find((asset) => asset.id === id)!;
      assetBytes.set(id, { bytes: (await store.get(row.r2Key)).bytes, mimeType: "image/png" });
    }
    const render = await renderSticker(resolveStickerConfiguration(document, { mood: "sad", pose: "wave" }), assetBytes);
    expect(render.times).toHaveLength(6);
    expect(render.bytes.byteLength).toBeGreaterThan(1000);
  } finally { await close(); }
});
