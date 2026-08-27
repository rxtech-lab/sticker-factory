import sharp from "sharp";
import { and, eq } from "drizzle-orm";
import { start } from "workflow/api";
import { getDatabase } from "@/lib/db/client";
import { assets, creatorProfiles, stickerPacks, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { createPack } from "@/lib/services/packs";
import { bindExports, acceptRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

async function runGeneration(jobId: string): Promise<void> {
  const run = await start(stickerGenerationWorkflow, [jobId]);
  await run.returnValue;
}

/**
 * A published pack owned by somebody *other* than the Playwright user.
 *
 * `getHealthyWebSession` mocks exactly one user under E2E, so that user can only ever be the
 * installer — the marketplace's interesting paths (install, creator byline, borrowed artwork)
 * all need a second owner to exist.
 */
async function seedMarketplace(db: ReturnType<typeof getDatabase>, installerId: string) {
  const creatorId = `${installerId}-creator`;
  const existing = await db.select({ slug: stickerPacks.slug, creatorId: stickerPacks.creatorId })
    .from(stickerPacks).where(eq(stickerPacks.creatorId, creatorId)).get();
  if (existing) {
    const profile = await db.select({ handle: creatorProfiles.handle }).from(creatorProfiles)
      .where(eq(creatorProfiles.userId, creatorId)).get();
    return { packSlug: existing.slug, creatorHandle: profile?.handle ?? "" };
  }

  await db.insert(users).values({
    id: creatorId,
    email: "playwright-creator@example.test",
    displayName: "Playwright Creator",
    createdAt: new Date(),
    updatedAt: new Date(),
  }).onConflictDoNothing();

  const stickerId = crypto.randomUUID();
  const revisionId = crypto.randomUUID();
  const systemAssetId = crypto.randomUUID();
  const now = new Date();
  const bytes = await sharp({ create: { width: 300, height: 300, channels: 4, background: { r: 120, g: 90, b: 220, alpha: 0.7 } } })
    .png().toBuffer();
  const inspection = await inspectImage(bytes);
  const key = objectKey(creatorId, systemAssetId, "image/png");
  await getObjectStore().put(key, { bytes, contentType: "image/png" });

  await db.insert(stickers).values({
    id: stickerId,
    ownerId: creatorId,
    title: "Playwright Loaf",
    kind: "static",
    status: "published",
    createdAt: now,
    updatedAt: now,
  });
  await db.insert(assets).values({
    id: systemAssetId,
    ownerId: creatorId,
    stickerId,
    kind: "system",
    state: "ready",
    r2Key: key,
    mimeType: "image/png",
    byteSize: inspection.byteSize,
    width: inspection.width,
    height: inspection.height,
    frameCount: inspection.frameCount,
    sha256: inspection.sha256,
    hasAlpha: inspection.hasAlpha,
    createdAt: now,
    readyAt: now,
  });
  await db.insert(stickerRevisions).values({
    id: revisionId,
    stickerId,
    kind: "static",
    candidateState: "accepted",
    documentJson: {
      version: 1,
      canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
      kind: "static",
      durationSeconds: 0,
      fps: 0,
      loop: "once",
      mp4Background: { type: "solid", color: "#FFFFFF" },
      layers: [],
    } as never,
    systemAssetId,
    previewAssetId: systemAssetId,
    createdAt: now,
    decidedAt: now,
  });
  await db.update(stickers).set({ activeRevisionId: revisionId }).where(eq(stickers.id, stickerId));

  const pack = await createPack(db, creatorId, {
    title: "Playwright Pack",
    summary: "Seeded for end-to-end tests.",
    stickerIds: [stickerId],
    state: "published",
  });
  return { packSlug: pack.slug, creatorHandle: pack.creator.handle };
}

export async function POST(request: Request) {
  if (process.env.NODE_ENV === "production"
    || process.env.STICKER_FACTORY_E2E !== "true"
    || request.headers.get("x-e2e-key") !== process.env.STICKER_FACTORY_E2E_KEY) {
    return new Response(null, { status: 404 });
  }
  const ownerId = process.env.STICKER_FACTORY_E2E_USER_ID!;
  const db = getDatabase();
  await db.insert(users).values({
    id: ownerId,
    email: "playwright@example.test",
    displayName: "Playwright User",
    createdAt: new Date(),
    updatedAt: new Date(),
  }).onConflictDoNothing();

  const marketplace = await seedMarketplace(db, ownerId);

  const existing = await db.select({ id: stickers.id }).from(stickers).where(and(
    eq(stickers.ownerId, ownerId),
    eq(stickers.title, "Playwright Cloud"),
  )).get();
  if (existing) return Response.json({ staticStickerId: existing.id, ...marketplace });

  const created = await createSticker(db, ownerId, {
    title: "Playwright Cloud",
    kind: "static",
    prompt: "A happy cloud waving hello",
    referenceAssetIds: [],
  });
  const firstTurn = await createChatTurn(db, ownerId, created.stickerId, {
    text: "A happy cloud waving hello",
    intent: "generate",
    attachments: [],
    imagePlacement: "replace",
  });
  await runGeneration(firstTurn.jobId);
  await acceptRevision(db, ownerId, created.stickerId, firstTurn.jobId);
  const secondTurn = await createChatTurn(db, ownerId, created.stickerId, {
    text: "Make the cloud coral pink",
    intent: "edit",
    baseRevisionId: firstTurn.jobId,
    targetLayerId: "hero",
    attachments: [],
    imagePlacement: "replace",
  });
  await runGeneration(secondTurn.jobId);
  await acceptRevision(db, ownerId, created.stickerId, secondTurn.jobId);

  const master = await db.select().from(assets).where(eq(assets.id, secondTurn.jobId)).get();
  if (!master) throw new Error("E2E master asset was not generated");
  const store = getObjectStore();
  const masterObject = await store.get(master.r2Key);
  const systemBytes = await sharp(masterObject.bytes).resize(300, 300, { fit: "contain" }).png().toBuffer();
  const systemInspection = await inspectImage(systemBytes);
  const systemAssetId = crypto.randomUUID();
  const systemKey = objectKey(ownerId, systemAssetId, "image/png");
  await store.put(systemKey, { bytes: systemBytes, contentType: "image/png" });
  await db.insert(assets).values({
    id: systemAssetId,
    ownerId,
    stickerId: created.stickerId,
    kind: "system",
    state: "ready",
    r2Key: systemKey,
    mimeType: "image/png",
    byteSize: systemInspection.byteSize,
    width: systemInspection.width,
    height: systemInspection.height,
    frameCount: systemInspection.frameCount,
    durationSeconds: systemInspection.durationSeconds,
    fps: systemInspection.fps,
    sha256: systemInspection.sha256,
    hasAlpha: systemInspection.hasAlpha,
    createdAt: new Date(),
    readyAt: new Date(),
  });
  await bindExports(db, ownerId, created.stickerId, {
    revisionId: secondTurn.jobId,
    pngAssetId: secondTurn.jobId,
    systemAssetId,
  });

  const animated = await createSticker(db, ownerId, {
    title: "Playwright Bounce",
    kind: "animated",
    prompt: "A bouncy blue star",
    referenceAssetIds: [],
  });
  const animatedTurn = await createChatTurn(db, ownerId, animated.stickerId, {
    text: "A bouncy blue star",
    intent: "generate",
    attachments: [],
    imagePlacement: "replace",
  });
  await runGeneration(animatedTurn.jobId);
  await acceptRevision(db, ownerId, animated.stickerId, animatedTurn.jobId);

  return Response.json({ staticStickerId: created.stickerId, animatedStickerId: animated.stickerId, ...marketplace });
}
