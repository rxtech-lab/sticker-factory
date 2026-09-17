/** Prepare shipped examples with the exact planning / approval / sprite-build pipeline used by
 * the app. Uses an isolated local Postgres and object store; AI calls use the configured gateway.
 * Run from server: bun scripts/generate-creation-previews.ts <option-id> <plan|build|export> <work-dir>
 * Inspect concept.png before running build. Checkpoints survive failed runs and retries. */
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { eq } from 'drizzle-orm';
import sharp from 'sharp';
import { GatewayAiProvider, setAiProviderForTests } from '@/lib/ai/gateway';
import { createDatabase, setDatabaseForTests } from '@/lib/db/client';
import { assets, generationJobs, plans, stickerRevisions, stickers, users } from '@/lib/db/schema';
import { createSticker, createChatTurn, retryFailedChatTurn } from '@/lib/services/stickers';
import { confirmPlan } from '@/lib/services/plans';
import { MemoryObjectStore, setObjectStoreForTests, inspectImage, type StoredObject } from '@/lib/storage/r2';
import { stickerGenerationWorkflow } from '@/workflows/sticker-generation';
import { creationPresetCatalog } from '@/lib/creation-presets/catalog';
import { StickerDocumentSchema, resolveStickerConfiguration } from '@/lib/contracts/sticker';
import { prepareRenditionAssets, animatedRenditionTiming } from '@/lib/render/renditions';
import { referencedAssetIds } from '@/lib/render/sticker-render';
import { createHash } from 'node:crypto';
import { frameFragment, IdFactory, type RenderAssets } from '@/lib/render/document-svg';

const [optionID, phase, directory] = process.argv.slice(2);
const group = creationPresetCatalog.groups.find(g => g.options.some(o => o.id === optionID));
const option = group?.options.find(o => o.id === optionID);
if (!group || !option || !['plan', 'build', 'export'].includes(phase) || !directory) {
  throw new Error('Expected <catalog-option-id> <plan|build|export> <local-work-directory>');
}
if (!process.env.AI_GATEWAY_API_KEY) throw new Error('AI_GATEWAY_API_KEY is required; previews must use real generation');
// This is asset preparation, not an end-user job. Never touch hosted projects, storage or billing.
Object.assign(process.env, { NODE_ENV: 'development', STICKER_FACTORY_MOCK_SERVICES: 'false' });
for (const key of Object.keys(process.env)) if (key.startsWith('RX_SUBSCRIPTION_') || key.startsWith('VERCEL_')) delete process.env[key];
const root = resolve(directory, optionID);
await mkdir(root, { recursive: true });
class LocalAssets extends MemoryObjectStore {
  private path(key: string) { return resolve(root, 'objects', Buffer.from(key).toString('base64url')); }
  override async put(key: string, object: StoredObject) {
    await mkdir(resolve(root, 'objects'), { recursive: true });
    await writeFile(this.path(key), object.bytes);
    await writeFile(this.path(key) + '.json', JSON.stringify({ contentType: object.contentType, metadata: object.metadata }));
  }
  override async get(key: string): Promise<StoredObject> {
    return { ...JSON.parse(await readFile(this.path(key) + '.json', 'utf8')), bytes: new Uint8Array(await readFile(this.path(key))) };
  }
  override async signedGet(key: string) { await this.get(key); return { url: 'https://preview.invalid/' + encodeURIComponent(key), expiresAt: new Date(Date.now() + 300000) }; }
}
type State = { ownerId: string; stickerId?: string; planJobId?: string; planId?: string; buildJobId?: string; prompt?: string; status?: string };
const stateFile = resolve(root, 'state.json');
const state: State = await readFile(stateFile, 'utf8').then(JSON.parse).catch(() => ({ ownerId: `creation-preview-${optionID}` }));
const save = async (status: string) => { state.status = status; await writeFile(stateFile, JSON.stringify(state, null, 2)); console.log(`[preview] ${optionID}: ${status}`); };
const handle = await createDatabase('pglite:' + resolve(root, 'database'));
await handle.migrate();
const db = handle.db;
const store = new LocalAssets();
setDatabaseForTests(db); setObjectStoreForTests(store); setAiProviderForTests(new GatewayAiProvider());
const run = async (id: string) => {
  const old = (await db.select().from(generationJobs).where(eq(generationJobs.id, id)))[0];
  if (old.state === 'succeeded') return id;
  if (old.state === 'failed' || old.state === 'cancelled') {
    const next = await retryFailedChatTurn(db, state.ownerId, state.stickerId!, old.sourceMessageId!);
    id = next.jobId;
  }
  const result = await stickerGenerationWorkflow(id);
  if (result.workflowStatus !== 'succeeded') {
    const job = (await db.select().from(generationJobs).where(eq(generationJobs.id, id)))[0];
    throw new Error(`Generation failed: ${job.errorMessage ?? id}`);
  }
  return id;
};
try {
  if (phase === 'plan') {
    if (!state.stickerId) {
      await db.insert(users).values({ id: state.ownerId }).onConflictDoNothing();
      const bytes = await sharp(await readFile(resolve('public', option.cover.slice(1)))).png().toBuffer();
      const inspection = await inspectImage(bytes);
      const assetId = crypto.randomUUID();
      const r2Key = `preview/${assetId}.png`;
      await store.put(r2Key, { bytes, contentType: 'image/png' });
      await db.insert(assets).values({ id: assetId, ownerId: state.ownerId, kind: 'reference', state: 'ready', r2Key,
        mimeType: 'image/png', byteSize: bytes.length, width: inspection.width, height: inspection.height,
        hasAlpha: inspection.hasAlpha, sha256: inspection.sha256, readyAt: new Date() });
      state.prompt = `Create one controllable sticker of the supplied pink limbless mascot. Preserve its exact asymmetric silhouette, pink body colors, unequal glossy eye proportions, and small horizontal default mouth. Keep body, eyes, and mouth visually separable. ${option.prompt} This is a catalog demonstration, no lettering and no unrelated scenery. Use exactly one sprite character with a stable front-facing face region. Use pose control id pose with exactly these 8 clip IDs, in this order: idle, wave, bounce, sway, wiggle, hop, spin, dance. Idle must visibly breathe and blink; every pose is a distinct animated looping body action, never a still or a whole-image transform. Keep the face region visible and stable; spin is a playful partial body turn with the face kept readable. Use 6 frames per clip and a 2-second loop. Use mood control id mood with exactly three expression IDs: neutral, happy, surprised. Independent pose and mood controls must combine correctly. Preserve the selected ${group.id} in all frames. Return a production sprite plan using the normal sprite source; render the approval reference before building.`;
      const selections = [{ groupId: 'style', optionIds: [group.id === 'style' ? optionID : 'bold-cartoon'] }, { groupId: 'theme', optionIds: group.id === 'theme' ? [optionID] : [] }];
      const created = await createSticker(db, state.ownerId, { title: `${option.title.en} preview`, kind: 'animated', prompt: state.prompt,
        controllable: true, posePreset: 'ultra', referenceAssetIds: [assetId], presets: { catalogVersion: creationPresetCatalog.version, selections } });
      state.stickerId = created.stickerId;
      const turn = await createChatTurn(db, state.ownerId, created.stickerId, { text: state.prompt, intent: 'generate', attachments: [{ assetId, kind: 'reference' }], imagePlacement: 'replace' });
      state.planJobId = turn.jobId;
      await save('planning');
    }
    state.planJobId = await run(state.planJobId!);
    const plan = (await db.select().from(plans).where(eq(plans.stickerId, state.stickerId!))).at(-1)!;
    state.planId = plan.id;
    await writeFile(resolve(root, 'plan.json'), JSON.stringify(plan.planJson, null, 2));
    for (const [name, id] of [['concept', plan.conceptAssetId], ['animation-summary', plan.animationPreviewAssetId]] as const) {
      if (!id) continue;
      const asset = (await db.select().from(assets).where(eq(assets.id, id)))[0];
      await writeFile(resolve(root, `${name}.png`), (await store.get(asset.r2Key)).bytes);
    }
    await save('ready-for-review');
  } else if (phase === 'build') {
    if (!state.planId) throw new Error('Plan and review the reference before building');
    if (!state.buildJobId) {
      state.buildJobId = (await confirmPlan(db, state.ownerId, state.stickerId!, state.planId)).jobId;
      await save('building');
    }
    state.buildJobId = await run(state.buildJobId);
    const revision = (await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, state.stickerId!))).at(-1)!;
    await writeFile(resolve(root, 'document.json'), JSON.stringify(revision.documentJson, null, 2));
    await save('built');
  } else {
    const document = StickerDocumentSchema.parse(JSON.parse(await readFile(resolve(root, 'document.json'), 'utf8')));
    if (document.kind !== 'animated' || !document.configuration) throw new Error('Expected a generated controllable document');
    const poses = document.configuration.controls.filter(c => c.type === 'choice').find(c => c.id === 'pose')?.options;
    const moods = document.configuration.controls.filter(c => c.type === 'choice').find(c => c.id === 'mood')?.options;
    if (poses?.length !== 8 || moods?.length !== 3) throw new Error('Expected exactly 8 poses and 3 moods');
    const renderAssets: RenderAssets = new Map();
    for (const asset of await db.select().from(assets).where(eq(assets.stickerId, state.stickerId!))) {
      if (asset.state === 'ready') { const object = await store.get(asset.r2Key); renderAssets.set(asset.id, { bytes: object.bytes, mimeType: object.contentType }); }
    }
    const output = resolve(root, 'export'); await mkdir(output, { recursive: true });
    await writeFile(resolve(output, 'document.json'), JSON.stringify(document, null, 2));
    const savedPlan = (await db.select().from(plans).where(eq(plans.id, state.planId!)))[0];
    const savedSticker = (await db.select().from(stickers).where(eq(stickers.id, state.stickerId!)))[0];
    await writeFile(resolve(output, 'approved-plan.json'), JSON.stringify(savedPlan.planJson, null, 2));
    await mkdir(resolve(output, 'assets'), { recursive: true });
    const imageFiles: Record<string, string> = {};
    for (const id of referencedAssetIds(document)) {
      const asset = renderAssets.get(id);
      if (!asset) throw new Error(`Missing generated document asset ${id}`);
      imageFiles[id] = `${id}.png`;
      await sharp(asset.bytes).png().toFile(resolve(output, 'assets', imageFiles[id]));
    }
    await writeFile(resolve(output, 'assets.json'), JSON.stringify(imageFiles, null, 2));
    const examples = [];
    for (const pose of poses) {
      const size = 512, previewSize = 320;
      let minX = size, minY = size, maxX = -1, maxY = -1;
      const rendered = [];
      for (const mood of moods) {
        const resolved = resolveStickerConfiguration(document, { pose: pose.id, mood: mood.id });
        const timing = animatedRenditionTiming(resolved as typeof document, 12);
        const prepared = await prepareRenditionAssets(resolved, renderAssets, size, timing.times);
        const frames = [];
        for (const time of timing.times) {
          const frame = frameFragment(resolved, time, size, prepared, new IdFactory());
          const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${size}" height="${size}"><defs>${frame.defs.join('')}</defs>${frame.body}</svg>`;
          const pixels = await sharp(Buffer.from(svg)).ensureAlpha().raw().toBuffer();
          frames.push(pixels);
          for (let index = 3; index < pixels.length; index += 4) {
            if (pixels[index] <= 16) continue;
            const x = ((index - 3) / 4) % size, y = Math.floor((index - 3) / 4 / size);
            minX = Math.min(minX, x); minY = Math.min(minY, y);
            maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
          }
        }
        rendered.push({ mood, timing, frames });
      }
      if (maxX < 0) throw new Error(`The ${pose.id} preview is empty`);
      // Frame every mood and every instant with one fixed crop, preserving the whole motion.
      // Otherwise sprite-sheet safety margins leave the character tiny inside the preview card.
      const padding = Math.ceil(Math.max(maxX - minX + 1, maxY - minY + 1) * 0.08);
      const left = Math.max(0, minX - padding), top = Math.max(0, minY - padding);
      const crop = { left, top, width: Math.min(size, maxX + padding + 1) - left, height: Math.min(size, maxY + padding + 1) - top };
      for (const { mood, timing, frames } of rendered) {
        const fitted = [];
        for (const pixels of frames) {
          fitted.push(await sharp(pixels, { raw: { width: size, height: size, channels: 4 } })
            .extract(crop).resize(previewSize, previewSize, { fit: 'contain', background: '#00000000', kernel: optionID === 'pixel' ? 'nearest' : 'lanczos3' })
            .raw().toBuffer());
        }
        const distinct = new Set(fitted.map(frame => createHash('sha256').update(frame).digest('hex')));
        if (distinct.size < 2) throw new Error(`The ${pose.id}/${mood.id} preview has no actual animation`);
        const name = `${pose.id}-${mood.id}.gif`;
        await sharp(Buffer.concat(fitted), { raw: { width: previewSize, height: previewSize * fitted.length, channels: 4, pageHeight: previewSize } })
          .gif({ loop: 0, delay: timing.delaysMs, colours: 128, dither: 0.5 }).toFile(resolve(output, name));
        examples.push({ pose: pose.id, mood: mood.id, file: name, frames: fitted.length, distinctFrames: distinct.size, crop });
      }
    }
    await writeFile(resolve(output, 'manifest.json'), JSON.stringify({ version: 1, poses, moods, examples, source: { prompt: state.prompt, catalogVersion: savedSticker.creationPresets?.catalogVersion, presets: savedSticker.creationPresets, optionId: optionID, workflow: 'stickerGenerationWorkflow', planId: state.planId, buildJobId: state.buildJobId } }, null, 2));
    await save('exported');
  }
} finally { await handle.close(); }
