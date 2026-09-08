import { readFileSync } from "node:fs";
import { afterEach, expect, it } from "vitest";
import sharp from "sharp";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { renderWorkingDocument } from "@/workflows/sticker-generation/turn-context";
import { eq } from "drizzle-orm";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { assets, generationEvents, generationJobs, users } from "@/lib/db/schema";
import { createSticker, listChatMessages } from "@/lib/services/stickers";
import { getOwnedAsset } from "@/lib/services/assets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState } from "@/tests/helpers/workflow";
import { beginJob, beginToolCall, finishToolCall } from "@/workflows/sticker-generation/turn-context";

afterEach(resetWorkflowTestState);
it("retains exact view-tool pixels for live events and reopened transcripts with owner access", async () => {
  const { db, close } = await createTestDatabase();
  try {
    setDatabaseForTests(db);
    const objects = new MemoryObjectStore();
    setObjectStoreForTests(objects);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "preview-owner" });
    const sticker = await createSticker(db, "preview-owner", { title: "Preview", kind: "static", prompt: "Cloud", referenceAssetIds: [] });
    await db.insert(generationJobs).values({ id: "preview-job", ownerId: "preview-owner", stickerId: sticker.stickerId, kind: "image", state: "queued" });
    const job = (await db.select().from(generationJobs).where(eq(generationJobs.stickerId, sticker.stickerId)).then(firstRow))!;
    await beginJob(job.id);
    const bytes = await sharp({ create: { width: 32, height: 32, channels: 4, background: "red" } }).png().toBuffer();
    for (const name of ["view_sticker", "view_plan_image"] as const) {
      const call = await beginToolCall(job, name);
      await finishToolCall(job, call, "complete", { bytes, mimeType: "image/png" });
      const transcript = await listChatMessages(db, job.ownerId, job.stickerId);
      const details = JSON.parse(transcript.data.find(row => row.id === call)!.toolDetails as string);
      expect(details.bytes).toContain("Image/media");
      expect(details.previewAssetId).toBeTruthy();
      const asset = (await db.select().from(assets).where(eq(assets.id, details.previewAssetId)).then(firstRow))!;
      expect(Buffer.from((await objects.get(asset.r2Key)).bytes)).toEqual(bytes);
      await expect(getOwnedAsset(db, "someone-else", asset.id)).rejects.toThrow();
      const events = await db.select().from(generationEvents).where(eq(generationEvents.jobId, job.id));
      expect(events.some(event => event.dataJson.toolDetails === JSON.stringify(details, null, 2))).toBe(true);
    }
    const document = StickerDocumentSchema.parse(JSON.parse(readFileSync("fixtures/sticker-document-v2.json", "utf8")));
    const expected = await renderWorkingDocument(document, job.ownerId);
    const layoutCall = await beginToolCall(job, "adjust_layout");
    await finishToolCall(job, layoutCall, "complete", { revision: 1, document, diagnostic: "x".repeat(17000) });
    const transcript = await listChatMessages(db, job.ownerId, job.stickerId);
    const layoutDetails = JSON.parse(transcript.data.find(row => row.id === layoutCall)!.toolDetails as string);
    expect(layoutDetails.previewAssetId).toBeTruthy();
    const layoutAsset = (await db.select().from(assets).where(eq(assets.id, layoutDetails.previewAssetId)).then(firstRow))!;
    expect(Buffer.from((await objects.get(layoutAsset.r2Key)).bytes)).toEqual(Buffer.from(expected.bytes));
    await expect(getOwnedAsset(db, "someone-else", layoutAsset.id)).rejects.toThrow();
  } finally { await close(); }
}, 30_000);
