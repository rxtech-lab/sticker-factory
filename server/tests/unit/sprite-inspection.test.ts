import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiImageInput, type AiSheetInspection, type AiSheetInspectionContext } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatThreads, generationJobs } from "@/lib/db/schema";
import { MemoryObjectStore, inspectImage, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { generatedLayers } from "@/workflows/sticker-generation/asset-generation";
import { generateSpriteArtwork, spriteClipAssetIds, spriteExpressionAssetId } from "@/workflows/sticker-generation/sprite-artwork";

afterEach(() => { setDatabaseForTests(undefined); setAiProviderForTests(undefined); setObjectStoreForTests(undefined); });

const PROBLEM = "frame 2 keeps a mouth on the bumper";
const FEEDBACK = `A previous attempt was rejected: ${PROBLEM}. Fix every listed problem in this drawing.`;

const plan = PlanV1Schema.parse({ title: "Car", summary: "A car with moods and poses", kind: "animated", timing: { durationSeconds: 3, fps: 24, loop: "loop" },
  layers: [{ layerId: "hero", name: "Car", x: 0.5, y: 0.5, scaleX: 1, scaleY: 1, source: {
    kind: "sprite", prompt: "A red cartoon car", face: "the windshield: both eyes and the mouth are inside the glass",
    clips: [
      { id: "idle", label: "Idle", prompt: "rocks gently", frames: [{ duration: 2.4 }, { duration: 0.18 }, { duration: 0.28 }, { duration: 0.22 }, { duration: 0.3 }, { duration: 1.2 }] },
      { id: "hop", label: "Hop", prompt: "hops once", frames: [{ duration: 0.4 }, { duration: 0.3 }, { duration: 0.35 }, { duration: 0.3 }] },
    ],
    expressions: [{ id: "neutral", label: "Neutral", prompt: "calm" }, { id: "happy", label: "Happy", prompt: "smiling" }, { id: "sad", label: "Sad", prompt: "downturned" }],
  } }],
  configuration: { controls: [
    { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }, { id: "sad", label: "Sad" }] },
    { id: "pose", type: "choice", label: "Pose", defaultValue: "idle", options: [{ id: "idle", label: "Idle" }, { id: "hop", label: "Hop" }] },
  ], variants: [
    { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
    { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
    { id: "sad", selections: { mood: "sad" }, layers: [{ layerId: "hero", expression: "sad" }] },
    { id: "idle", selections: { pose: "idle" }, layers: [{ layerId: "hero", clip: "idle" }] },
    { id: "hop", selections: { pose: "hop" }, layers: [{ layerId: "hero", clip: "hop" }] },
  ] } });

/** A provider whose inspector rejects by script, recording every request and inspection it sees. */
class Provider extends MockAiProvider {
  requests: AiImageInput[] = [];
  inspections: AiSheetInspectionContext[] = [];
  constructor(private reject: (input: AiSheetInspectionContext, seen: number) => boolean) { super(); }
  override async generateStickerImage(input: AiImageInput) { this.requests.push(input); return super.generateStickerImage(input); }
  override async inspectSpriteSheet(input: AiSheetInspectionContext): Promise<AiSheetInspection> {
    const seen = this.inspections.filter((item) => item.kind === input.kind).length;
    this.inspections.push(input);
    return this.reject(input, seen) ? { ok: false, problems: [PROBLEM] } : { ok: true };
  }
}

async function setup(provider: Provider) {
  const { db, close } = await createTestDatabase();
  setDatabaseForTests(db);
  const store = new MemoryObjectStore(); setObjectStoreForTests(store);
  setAiProviderForTests(provider);
  await seedUser(db, "owner");
  const sticker = await seedPublishedSticker(db, "owner", { kind: "animated" });
  await db.insert(chatThreads).values({ id: crypto.randomUUID(), stickerId: sticker.stickerId, ownerId: "owner" });
  const [job] = await db.insert(generationJobs).values({ id: crypto.randomUUID(), stickerId: sticker.stickerId, ownerId: "owner", kind: "compose", state: "running" }).returning();
  const tile = await sharp({ create: { width: 256, height: 256, channels: 4, background: "red" } }).png().toBuffer();
  const blank = await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer();
  const approved = await sharp(blank).composite([{ input: tile, left: 384, top: 384 }]).png().toBuffer();
  const separated = generatedLayers(plan, job.id)[0].assetId;
  const r2Key = objectKey("owner", separated, "image/png");
  await store.put(r2Key, { bytes: approved, contentType: "image/png" });
  await db.insert(assets).values({ id: separated, ownerId: "owner", stickerId: sticker.stickerId, kind: "master", state: "ready", r2Key,
    mimeType: "image/png", byteSize: approved.length, width: 1024, height: 1024, sha256: (await inspectImage(approved)).sha256, hasAlpha: true });
  const assetState = async (id: string) => (await db.select({ state: assets.state }).from(assets).where(eq(assets.id, id)))[0]?.state;
  const run = () => generateSpriteArtwork(job, sticker.stickerId, plan, job.id, { bytes: approved, mimeType: "image/png" });
  return { db, close, store, job, run, assetState, rawIdle: spriteClipAssetIds(job.id, "hero", "idle").raw, expressionsId: spriteExpressionAssetId(job.id, "hero") };
}

it("redraws a body sheet the inspector rejects, once, with the problems in the prompt", async () => {
  const provider = new Provider((input, seen) => input.kind === "clips" && seen === 0);
  const t = await setup(provider);
  try {
    const builds = await t.run();
    // idle (rejected), idle again, hop, expressions.
    expect(provider.requests).toHaveLength(4);
    expect(provider.requests[0].prompt).not.toContain("A previous attempt was rejected");
    expect(provider.requests[1].prompt).toContain(FEEDBACK);
    expect(provider.requests[1].sheet).toMatchObject({ columns: 3, rows: 2, count: 6, facePlaceholder: true, faceRegion: "the windshield: both eyes and the mouth are inside the glass" });
    expect(provider.requests[2].prompt).not.toContain("A previous attempt was rejected");
    expect(await t.assetState(t.rawIdle)).toBe("ready");
    // The inspector saw the raw sheet, opening included, with the plan's face region.
    expect(provider.inspections.map((item) => item.kind)).toEqual(["clips", "clips", "clips", "expressions"]);
    expect(provider.inspections[0]).toMatchObject({ character: "Car", face: plan.layers[0].source.kind === "sprite" ? plan.layers[0].source.face : undefined, sheet: { columns: 3, rows: 2, count: 6 } });
    const stored = (await t.store.get(objectKey("owner", t.rawIdle, "image/png"))).bytes;
    expect(await sharp(provider.inspections[1].image.bytes).ensureAlpha().raw().toBuffer()).toEqual(await sharp(stored).ensureAlpha().raw().toBuffer());
    expect(builds.get("hero")!.clips.map((clip) => clip.frames.length)).toEqual([6, 4]);
    // A replay reuses the checkpoints: nothing is bought or inspected again.
    await t.run();
    expect(provider.requests).toHaveLength(4);
    expect(provider.inspections).toHaveLength(4);
  } finally { await t.close(); }
});

it("redraws a face-plate sheet the inspector rejects with the same one-retry rule", async () => {
  const provider = new Provider((input, seen) => input.kind === "expressions" && seen === 0);
  const t = await setup(provider);
  try {
    const builds = await t.run();
    expect(provider.requests).toHaveLength(4);
    const [, , first, retry] = provider.requests;
    expect(first.sheet).toMatchObject({ columns: 2, rows: 2, count: 3, tiles: true });
    expect(retry.sheet).toMatchObject({ columns: 2, rows: 2, count: 3, tiles: true });
    expect(first.prompt).not.toContain("A previous attempt was rejected");
    expect(retry.prompt).toContain(FEEDBACK);
    expect(retry.references).toHaveLength(3);
    expect(provider.inspections.at(-1)).toMatchObject({ kind: "expressions", expressions: ["Neutral", "Happy", "Sad"], sheet: { columns: 2, rows: 2, count: 3 } });
    expect(await t.assetState(t.expressionsId)).toBe("ready");
    expect(builds.get("hero")!.expressions.tiles.map((tile) => tile.id)).toEqual(["neutral", "happy", "sad"]);
  } finally { await t.close(); }
});

it("gives up after the second rejection, and re-inspects the saved sheet before reusing it on retry", async () => {
  let accept = false;
  const provider = new Provider((input) => input.kind === "clips" && !accept);
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow(`Generated sheet was rejected: ${PROBLEM}`);
    expect(provider.requests).toHaveLength(2);
    expect(provider.inspections).toHaveLength(2);
    expect(await t.assetState(t.rawIdle)).toBe("failed");

    // The user retries and the inspector now passes the saved pixels: they are inspected again on
    // the recovery path rather than trusted, then reused, so only hop and the faces are bought.
    accept = true;
    const builds = await t.run();
    expect(provider.requests).toHaveLength(4);
    expect(provider.inspections.map((item) => item.kind)).toEqual(["clips", "clips", "clips", "clips", "expressions"]);
    expect(await t.assetState(t.rawIdle)).toBe("ready");
    expect(builds.get("hero")!.clips).toHaveLength(2);
  } finally { await t.close(); }
});
