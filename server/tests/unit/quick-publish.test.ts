import { readFileSync } from "node:fs";
import sharp from "sharp";
import { and, eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { assets, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { quickPublishSticker } from "@/lib/services/quick-publish";
import { createCandidateRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";

/** Generated-looking artwork: a cut-out subject on a transparent square. */
async function artwork(): Promise<Buffer> {
  const dimension = 1_024;
  const pixels = Buffer.alloc(dimension * dimension * 4, 0);
  for (let y = 200; y < 800; y += 1) {
    for (let x = 200; x < 800; x += 1) {
      const index = (y * dimension + x) * 4;
      pixels[index] = 220;
      pixels[index + 1] = 70;
      pixels[index + 2] = 110;
      pixels[index + 3] = 255;
    }
  }
  return sharp(pixels, { raw: { width: dimension, height: dimension, channels: 4 } }).png().toBuffer();
}

describe("quick mode's server-rendered publish", () => {
  let db: Database;
  let close: () => Promise<void>;
  let store: MemoryObjectStore;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    store = new MemoryObjectStore();
    setObjectStoreForTests(store);
    await db.insert(users).values({ id: "owner-a", email: "a@example.test", createdAt: new Date(), updatedAt: new Date() });
  });

  afterEach(async () => {
    setObjectStoreForTests(undefined);
    await close();
  });

  /** A sticker with one outstanding candidate, exactly as a Messages-extension generation leaves it. */
  async function seedCandidate(kind: "static" | "animated") {
    const sticker = await createSticker(db, "owner-a", {
      title: "Corgi", kind, prompt: "A joyful corgi", referenceAssetIds: [],
    });
    const assetId = crypto.randomUUID();
    const bytes = await artwork();
    const r2Key = objectKey("owner-a", assetId, "image/png");
    await store.put(r2Key, { bytes: new Uint8Array(bytes), contentType: "image/png" });
    await db.insert(assets).values({
      id: assetId,
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      kind: "master",
      state: "ready",
      r2Key,
      mimeType: "image/png",
      byteSize: bytes.byteLength,
      width: 1_024,
      height: 1_024,
      sha256: "a".repeat(64),
      hasAlpha: true,
      createdAt: new Date(),
      readyAt: new Date(),
    });

    const layer = {
      id: "hero",
      name: "Hero",
      hidden: false,
      type: "image" as const,
      assetId,
      contentMode: "fit" as const,
    };
    // The animated case is derived from the shipped fixture rather than written out here: its
    // keyframes are a real generated animation, and a hand-rolled one would only re-derive the
    // schema's own defaults. Its frame rate is dropped to keep the test's frame count — and so its
    // rasterisation count — small.
    const document = StickerDocumentSchema.parse(kind === "static" ? {
      version: 1,
      canvas: { width: 1_024, height: 1_024, coordinateSpace: "normalized", transparent: true },
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers: [layer],
    } : (() => {
      const fixture = JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8"));
      const animated = fixture.layers.find((candidate: { type: string }) => candidate.type === "image");
      return { ...fixture, fps: 8, layers: [{ ...animated, assetId }] };
    })());

    const turn = await createChatTurn(db, "owner-a", sticker.stickerId, {
      text: "A joyful corgi", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    const revisionId = await createCandidateRevision(db, {
      ownerId: "owner-a",
      stickerId: sticker.stickerId,
      sourceMessageId: turn.messageId,
      document,
      masterAssetId: assetId,
      previewAssetId: assetId,
    });
    return { stickerId: sticker.stickerId, revisionId, r2Key };
  }

  it("accepts the candidate and publishes a static sticker", async () => {
    const { stickerId, revisionId } = await seedCandidate("static");

    const result = await quickPublishSticker(db, "owner-a", stickerId);
    expect(result.status).toBe("published");
    expect(result.sourceRevisionId).toBe(revisionId);

    const sticker = await db.select().from(stickers).where(eq(stickers.id, stickerId)).then(firstRow);
    expect(sticker?.status).toBe("published");
    expect(sticker?.activeRevisionId).toBe(result.revisionId);

    const published = await db.select().from(stickerRevisions)
      .where(eq(stickerRevisions.id, result.revisionId)).then(firstRow);
    expect(published?.pngAssetId).toBeTruthy();
    expect(published?.systemAssetId).toBeTruthy();
    expect(published?.attachmentMediumAssetId).toBeTruthy();
    expect(published?.attachmentSmallAssetId).toBeTruthy();

    // The rendition Messages actually carries, held to Apple's ceiling.
    const system = await db.select().from(assets)
      .where(eq(assets.id, published!.systemAssetId!)).then(firstRow);
    expect(system?.kind).toBe("system");
    expect([300, 408, 618]).toContain(system?.width);
    expect(system?.byteSize).toBeLessThan(500_000);
    await expect(store.get(system!.r2Key)).resolves.toBeTruthy();
  });

  it("reports each render step once as it starts and once as it finishes", async () => {
    const { stickerId } = await seedCandidate("static");
    const steps: Array<{ id: string; status: string; progress: number }> = [];

    await quickPublishSticker(db, "owner-a", stickerId, async (step) => {
      steps.push(step);
    });

    // Every step is announced twice, in order, and the bar only ever moves forward — the extension
    // keys its rows on the id and would draw a second stuck spinner for a step announced once.
    expect(steps.map((step) => `${step.id}:${step.status}`)).toEqual([
      "render_artwork:streaming",
      "render_artwork:complete",
      "render_attachments:streaming",
      "render_attachments:complete",
      "render_sizes:streaming",
      "render_sizes:complete",
      "save_renditions:streaming",
      "save_renditions:complete",
    ]);
    const progress = steps.map((step) => step.progress);
    expect([...progress].sort((a, b) => a - b)).toEqual(progress);
    expect(progress.at(-1)).toBeLessThanOrEqual(1);
  });

  it("publishes an animated sticker with a real APNG", async () => {
    const { stickerId } = await seedCandidate("animated");

    const result = await quickPublishSticker(db, "owner-a", stickerId);
    expect(result.status).toBe("published");

    const published = await db.select().from(stickerRevisions)
      .where(eq(stickerRevisions.id, result.revisionId)).then(firstRow);
    expect(published?.apngAssetId).toBeTruthy();
    // An animated publish never carries a static PNG relation; `bindExports` refuses one.
    expect(published?.pngAssetId).toBeNull();

    const sharing = await db.select().from(assets).where(eq(assets.id, published!.apngAssetId!)).then(firstRow);
    expect(sharing?.kind).toBe("apng");
    // 8 fps across the fixture's 2 s cycle, and the 0.6 s loop hold rides on the last frame's delay.
    expect(sharing?.frameCount).toBe(16);
    expect(sharing?.durationSeconds).toBeCloseTo(2.6, 1);

    const system = await db.select().from(assets).where(eq(assets.id, published!.systemAssetId!)).then(firstRow);
    expect(system?.frameCount).toBeGreaterThan(1);
    expect(system?.byteSize).toBeLessThan(500_000);
  });

  it("is idempotent, so a retried step republishes rather than forking", async () => {
    const { stickerId } = await seedCandidate("static");
    const first = await quickPublishSticker(db, "owner-a", stickerId);
    const second = await quickPublishSticker(db, "owner-a", stickerId);
    expect(second.revisionId).toBe(first.revisionId);

    const revisions = await db.select().from(stickerRevisions)
      .where(and(eq(stickerRevisions.stickerId, stickerId), eq(stickerRevisions.candidateState, "accepted")));
    // The candidate that was accepted, and the published revision derived from it. No third row.
    expect(revisions).toHaveLength(2);
  });

  it("refuses a document whose artwork has gone missing", async () => {
    // The row stays; its bytes go. That is the shape the failure actually takes in production —
    // a swept object, or a store that will not answer — and deleting the asset row instead would
    // only exercise the schema's own foreign keys.
    const { stickerId, r2Key } = await seedCandidate("static");
    await store.delete(r2Key);
    await expect(quickPublishSticker(db, "owner-a", stickerId))
      .rejects.toMatchObject({ code: "QUICK_PUBLISH_UNSUPPORTED" });
  });

  it("refuses another owner's sticker", async () => {
    const { stickerId } = await seedCandidate("static");
    await db.insert(users).values({ id: "owner-b", createdAt: new Date(), updatedAt: new Date() });
    await expect(quickPublishSticker(db, "owner-b", stickerId))
      .rejects.toMatchObject({ code: "STICKER_NOT_FOUND" });
  });
});
