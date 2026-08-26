import sharp from "sharp";
import { and, eq } from "drizzle-orm";
import { start } from "workflow/api";
import { getDatabase } from "@/lib/db/client";
import { assets, stickers, users } from "@/lib/db/schema";
import { bindExports, acceptRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { getObjectStore, inspectImage, objectKey } from "@/lib/storage/r2";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

async function runGeneration(jobId: string): Promise<void> {
  const run = await start(stickerGenerationWorkflow, [jobId]);
  await run.returnValue;
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

  const existing = await db.select({ id: stickers.id }).from(stickers).where(and(
    eq(stickers.ownerId, ownerId),
    eq(stickers.title, "Playwright Cloud"),
  )).get();
  if (existing) return Response.json({ staticStickerId: existing.id });

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

  return Response.json({ staticStickerId: created.stickerId, animatedStickerId: animated.stickerId });
}
