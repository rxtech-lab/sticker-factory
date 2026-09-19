import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { setAiProviderForTests, type AiImageInput, type AiImageOutput, type AiSheetInspection, type AiSheetInspectionContext } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, chatThreads, generationJobs } from "@/lib/db/schema";
import { registerExpressionTiles } from "@/lib/render/sprite-registration";
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
  constructor(
    private reject: (input: AiSheetInspectionContext, seen: number) => boolean,
    private mutate?: (output: AiImageOutput, input: AiImageInput) => Promise<AiImageOutput>,
  ) { super(); }
  override async generateStickerImage(input: AiImageInput) {
    this.requests.push(input);
    const output = await super.generateStickerImage(input);
    return this.mutate ? this.mutate(output, input) : output;
  }
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
    expect(provider.inspections.at(-1)?.faceGuide?.bytes).toEqual(retry.references[2].bytes);
    expect(provider.inspections.at(-1)).toMatchObject({ kind: "expressions", expressions: ["Neutral", "Happy", "Sad"], sheet: { columns: 2, rows: 2, count: 3 } });
    expect(await t.assetState(t.expressionsId)).toBe("ready");
    expect(builds.get("hero")!.expressions.tiles.map((tile) => tile.id)).toEqual(["neutral", "happy", "sad"]);
  } finally { await t.close(); }
});

it("gives up once the redraw budget is spent, and re-inspects the saved sheet before reusing it on retry", async () => {
  let accept = false;
  const provider = new Provider((input) => input.kind === "clips" && !accept);
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow(`Generated sheet was rejected: ${PROBLEM}`);
    expect(provider.requests).toHaveLength(3);
    expect(provider.inspections).toHaveLength(3);
    expect(await t.assetState(t.rawIdle)).toBe("failed");

    // The user retries and the inspector now passes the saved pixels: they are inspected again on
    // the recovery path rather than trusted, then reused, so only hop and the faces are bought.
    accept = true;
    const builds = await t.run();
    expect(provider.requests).toHaveLength(5);
    expect(provider.inspections.map((item) => item.kind)).toEqual(["clips", "clips", "clips", "clips", "clips", "expressions"]);
    expect(await t.assetState(t.rawIdle)).toBe("ready");
    expect(builds.get("hero")!.clips).toHaveLength(2);
  } finally { await t.close(); }
});

async function clipOuterEdge(output: AiImageOutput): Promise<AiImageOutput> {
  const edge = await sharp({ create: { width: 30, height: 180, channels: 4, background: "red" } }).png().toBuffer();
  return { ...output, bytes: await sharp(output.bytes).composite([{ input: edge, left: 0, top: 100 }]).png().toBuffer() };
}

it.each(["clipped", "empty"])("automatically redraws an expression sheet with an %s cell", async (failure) => {
  let damaged = false;
  const provider = new Provider(() => false, async (output, input) => {
    if (!input.sheet?.tiles || damaged) return output;
    damaged = true;
    return failure === "clipped" ? clipOuterEdge(output) : {
      ...output, bytes: await sharp({ create: { width: 1024, height: 1024, channels: 4, background: "#00000000" } }).png().toBuffer(),
    };
  });
  const t = await setup(provider);
  try {
    const builds = await t.run();
    expect(provider.requests).toHaveLength(4);
    expect(provider.requests[3].prompt).toContain(failure === "clipped" ? "20%" : "no used cell may be empty");
    expect(provider.inspections.map((input) => input.kind)).toEqual(["clips", "clips", "expressions"]);
    expect(await t.assetState(t.expressionsId)).toBe("ready");
    expect(builds.get("hero")!.expressions.tiles).toHaveLength(3);
    await t.run();
    expect(provider.requests).toHaveLength(4);
  } finally { await t.close(); }
});

it.each([false, true])("repairs expression grid drift without redrawing, including thin boundary contact: %s", async (thin) => {
  let original: Uint8Array | undefined;
  const provider = new Provider(() => false, async (output, input) => {
    if (!input.sheet?.tiles) return output;
    // Complete, separated patches. The first crosses x=512; a thin extension passes the atlas
    // border-count gate but is still caught by the expression registrar's tight bounds.
    const first = thin
      ? '<rect x="180" y="150" width="240" height="160"/><rect x="410" y="200" width="110" height="10"/>'
      : '<rect x="180" y="150" width="340" height="160"/>';
    original = await sharp(Buffer.from(`<svg width="1024" height="1024"><g fill="red">${first}<rect x="620" y="150" width="240" height="160"/><rect x="180" y="680" width="240" height="160"/></g></svg>`)).png().toBuffer();
    return { ...output, bytes: original };
  });
  const t = await setup(provider);
  try {
    const builds = await t.run();
    expect(provider.requests).toHaveLength(3);
    const stored = (await t.store.get(objectKey("owner", t.expressionsId, "image/png"))).bytes;
    expect(stored).not.toEqual(original);
    expect(provider.inspections.at(-1)!.image.bytes).toEqual(stored);
    const tiles = await registerExpressionTiles(stored, { columns: 2, rows: 2, frameCount: 3 });
    expect(builds.get("hero")!.expressions.tiles.map(({ x, y, width, height }) => ({ x, y, width, height }))).toEqual(tiles);
    const [row] = await t.db.select().from(assets).where(eq(assets.id, t.expressionsId));
    expect(row.sha256).toBe((await inspectImage(stored)).sha256);
    expect(row.state).toBe("ready");
    await t.run();
    expect(provider.requests).toHaveLength(3);
  } finally { await t.close(); }
});

it.each(["clips", "expressions"])("stops after the corrective redraws when %s remain clipped", async (kind) => {
  let fail = true;
  const provider = new Provider(() => false, async (output, input) =>
    fail && (kind === "expressions" ? input.sheet?.tiles : input.sheet?.facePlaceholder) ? clipOuterEdge(output) : output);
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow("Generated pose frame 1 is clipped at its cell boundary");
    const count = kind === "clips" ? 3 : 5;
    expect(provider.requests).toHaveLength(count);
    // The correction escalates: a model that ignored the first margin rule is told to draw smaller.
    const redraws = provider.requests.slice(-2).map((request) => request.prompt);
    expect(redraws[0]).toContain("20%");
    expect(redraws[1]).toContain("25%");
    expect(await t.assetState(kind === "clips" ? t.rawIdle : t.expressionsId)).toBe("failed");
    fail = false;
    await t.run();
    // Completed clips are retained when faces fail; a rejected sheet is never checkpointed.
    expect(provider.requests).toHaveLength(count + (kind === "clips" ? 3 : 1));
    if (kind === "clips") expect(provider.requests[count].prompt).toContain("20%");
  } finally { await t.close(); }
});

it("shares the redraw budget between clipping and visual inspection", async () => {
  let clipped = false;
  const provider = new Provider((input) => input.kind === "clips", async (output, input) => {
    if (!input.sheet?.facePlaceholder || clipped) return output;
    clipped = true;
    return clipOuterEdge(output);
  });
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow(PROBLEM);
    expect(provider.requests).toHaveLength(3);
    expect(provider.inspections).toHaveLength(2);
    expect(await t.assetState(t.rawIdle)).toBe("failed");
  } finally { await t.close(); }
});

it.each(["generation", "inspection"])("does not buy another image after a %s service failure", async (stage) => {
  const provider = new Provider(() => {
    if (stage === "inspection") throw new Error("Inspection service unavailable");
    return false;
  }, async (output) => {
    if (stage === "generation") throw new Error("Image service unavailable");
    return output;
  });
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow("service unavailable");
    expect(provider.requests).toHaveLength(1);
    if (stage === "inspection") {
      await expect(t.run()).rejects.toThrow("service unavailable");
      expect(provider.requests).toHaveLength(1); // A failed saved inspection must not trigger a purchase either.
    }
  } finally { await t.close(); }
});

it("honours cancellation before starting a corrective redraw", async () => {
  const provider = new Provider(() => false);
  const t = await setup(provider);
  provider.inspectSpriteSheet = async () => {
    await t.db.update(generationJobs).set({ state: "cancelled" }).where(eq(generationJobs.id, t.job.id));
    return { ok: false, problems: [PROBLEM] };
  };
  try {
    await expect(t.run()).rejects.toThrow("Generation was cancelled");
    expect(provider.requests).toHaveLength(1);
  } finally { await t.close(); }
});


it("re-inspects failed expression pixels with the body guide and reuses them only after acceptance", async () => {
  let accept = false;
  const provider = new Provider(input => input.kind === "expressions" && !accept);
  const t = await setup(provider);
  try {
    await expect(t.run()).rejects.toThrow(`Generated sheet was rejected: ${PROBLEM}`);
    expect(provider.requests).toHaveLength(5);
    expect(await t.assetState(t.expressionsId)).toBe("failed");
    accept = true;
    const builds = await t.run();
    expect(provider.requests).toHaveLength(5);
    expect(provider.inspections.filter(input => input.kind === "expressions")).toHaveLength(4);
    expect(provider.inspections.at(-1)?.faceGuide).toBeDefined();
    expect(await t.assetState(t.expressionsId)).toBe("ready");
    expect(builds.get("hero")!.expressions.tiles).toHaveLength(3);
  } finally { await t.close(); }
});
