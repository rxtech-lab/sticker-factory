import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiImageInput, type AiImageOutput } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatThreads, generationJobs } from "@/lib/db/schema";
import { validateDocumentAssetReferences } from "@/lib/services/sticker-documents";
import { MemoryObjectStore, inspectImage, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { documentFromPlan } from "@/workflows/sticker-generation/asset-generation";
import { generatePlannedVariants } from "@/workflows/sticker-generation/configurable-artwork";

afterEach(() => { setDatabaseForTests(undefined); setAiProviderForTests(undefined); setObjectStoreForTests(undefined); });

it("reuses the approved reference and resumes completed variants after a bad sprite sheet", async () => {
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
    const frames = await sharp(blank).composite([{ input: tile, left: 128, top: 384 }, { input: tile, left: 640, top: 352 }]).png().toBuffer();
    const sourceId = crypto.randomUUID(), r2Key = objectKey("owner", sourceId, "image/png"), inspection = await inspectImage(approved);
    await store.put(r2Key, { bytes: approved, contentType: "image/png" });
    await db.insert(assets).values({ id: sourceId, ownerId: "owner", stickerId: sticker.stickerId, kind: "master", state: "ready", r2Key,
      mimeType: "image/png", byteSize: approved.length, width: 1024, height: 1024, sha256: inspection.sha256, hasAlpha: true });
    const requests: AiImageInput[] = [];
    let failedSheet = false;
    class Provider extends MockAiProvider {
      override async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
        requests.push(input);
        if (input.prompt.includes("sprite sheet")) {
          if (!failedSheet) { failedSheet = true; return { bytes: blank, mimeType: "image/png" }; }
          return { bytes: frames, mimeType: "image/png" };
        }
        return { bytes: approved, mimeType: "image/png" };
      }
    }
    setAiProviderForTests(new Provider());
    const plan = PlanV1Schema.parse({ title: "Pet", summary: "Expressions with body motion", kind: "animated", timing: { durationSeconds: 2, fps: 24, loop: "loop" },
      layers: [{ layerId: "pet", name: "Pet", source: { kind: "existing", assetId: sourceId }, x: 0.5, y: 0.5, scaleX: 1, scaleY: 1,
        animations: [{ type: "bounce", height: 0.05, bounces: 1, delay: 0, duration: 0.5 }] }],
      configuration: { controls: [{ id: "mood", type: "choice", label: "Mood", defaultValue: "rest", options: [{ id: "rest", label: "Rest" }, { id: "happy", label: "Happy" }, { id: "wave", label: "Wave" }] }], variants: [
        { id: "rest", selections: { mood: "rest" }, layers: [{ layerId: "pet", source: { kind: "base" } }] },
        { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "pet", source: { kind: "generate", prompt: "Happy expression" } }] },
        { id: "wave", selections: { mood: "wave" }, layers: [{ layerId: "pet", source: { kind: "frames", prompt: "Wave", columns: 2, rows: 1, frameCount: 2, frameRate: 2, playback: "loop" } }] },
      ] } });
    const reference = { bytes: approved, mimeType: "image/png" };
    await expect(generatePlannedVariants(job, sticker.stickerId, plan, job.id, reference)).rejects.toThrow("empty");
    const document = documentFromPlan(plan, job.id);
    await expect(validateDocumentAssetReferences(db, "owner", sticker.stickerId, document)).rejects.toThrow();
    await generatePlannedVariants(job, sticker.stickerId, plan, job.id, reference);
    expect(requests).toHaveLength(3); // The ready happy expression was reused, not bought again.
    for (const request of requests) {
      expect(request.keepFrame).toBe(true);
      expect(request.mode).toBe("conversation_edit");
      expect(request.references[0].bytes).toEqual(approved);
      expect(request.references[1].bytes).toEqual(approved);
    }
    await expect(validateDocumentAssetReferences(db, "owner", sticker.stickerId, document)).resolves.toBeInstanceOf(Map);
    expect(document.layers[0].animation.position.length).toBeGreaterThan(1);
    const generated = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(generated.filter((asset) => asset.kind === "sequence")).toMatchObject([{ state: "ready", frameCount: 2, sequenceColumns: 2 }]);
  } finally { await close(); }
});
