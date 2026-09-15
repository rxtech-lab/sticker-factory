import { and, desc, eq, inArray, sql } from "drizzle-orm";
import { z } from "zod";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, getDatabase } from "@/lib/db/client";
import { assets, chatMessages, generationEvents, generationJobs, type GenerationJobRow } from "@/lib/db/schema";
import { generationExecutionContext } from "@/lib/services/generation-retry";

export const BuildReviewCheckpointSchema = z.object({
  document: StickerDocumentSchema,
  reviewed: StickerDocumentSchema.optional(),
  configurationCursor: z.number().int().nonnegative(),
  revision: z.number().int().nonnegative(),
  viewedRevision: z.number().int().min(-1),
  viewedPlanImage: z.boolean(),
  finalized: z.boolean(),
  toolCalls: z.record(z.string(), z.number().int().nonnegative()).optional(),
});
export type BuildReviewCheckpoint = z.infer<typeof BuildReviewCheckpointSchema>;

/** Scoped to the immutable confirmed build, so chat retries and button retries share progress. */
export async function loadBuildCheckpoint<T>(job: GenerationJobRow, assetJobId: string, key: string, schema: z.ZodType<T>): Promise<T | undefined> {
  const db = await getDatabase();
  const event = await db.select({ data: generationEvents.dataJson }).from(generationEvents)
    .innerJoin(generationJobs, eq(generationJobs.id, generationEvents.jobId)).where(and(
      eq(generationEvents.ownerId, job.ownerId), eq(generationJobs.ownerId, job.ownerId),
      eq(generationJobs.stickerId, job.stickerId), eq(generationEvents.type, "progress"),
      sql`${generationEvents.dataJson}->>'checkpoint' = 'plan_build'`,
      sql`${generationEvents.dataJson}->>'assetJobId' = ${assetJobId}`,
      sql`${generationEvents.dataJson}->>'key' = ${key}`,
    )).orderBy(desc(generationEvents.id)).limit(1).then(firstRow);
  return event ? schema.parse(event.data.value) : undefined;
}

export async function saveBuildCheckpoint(job: GenerationJobRow, assetJobId: string, key: string, value: unknown): Promise<void> {
  const db = await getDatabase();
  await db.transaction(async (tx) => {
    // Serialize with Stop: a cancelled task cannot replace the last usable checkpoint.
    const claimed = await tx.update(generationJobs).set({ updatedAt: new Date() }).where(and(
      eq(generationJobs.id, job.id), eq(generationJobs.ownerId, job.ownerId), eq(generationJobs.state, "running"),
    )).returning({ id: generationJobs.id });
    if (!claimed.length) throw new Error("Generation was cancelled before saving progress");
    await tx.insert(generationEvents).values({
      jobId: job.id, ownerId: job.ownerId, type: "progress",
      dataJson: { checkpoint: "plan_build", assetJobId, key, value }, createdAt: new Date(),
    });
  });
}

export async function buildAssetsReady(job: GenerationJobRow, ids: string[]): Promise<boolean> {
  const unique = [...new Set(ids)];
  if (!unique.length) return true;
  const rows = await (await getDatabase()).select({ id: assets.id }).from(assets).where(and(
    eq(assets.ownerId, job.ownerId), eq(assets.stickerId, job.stickerId), eq(assets.state, "ready"), inArray(assets.id, unique),
  ));
  return rows.length === unique.length;
}

/** Old builds have tool outcomes but no checkpoints. Do not announce their cached work as new. */
export async function completedBuildSteps(job: GenerationJobRow): Promise<Set<string>> {
  const db = await getDatabase();
  const { attemptIds } = await generationExecutionContext(db, job);
  const rows = await db.select().from(chatMessages).where(and(
    eq(chatMessages.ownerId, job.ownerId), inArray(chatMessages.jobId, attemptIds),
    eq(chatMessages.role, "system"), eq(chatMessages.kind, "status"),
  )).orderBy(chatMessages.sequence);
  const latest = new Map(rows.map((row) => [row.content, row.status]));
  return new Set([...latest].filter(([, status]) => status === "complete").map(([name]) => name));
}
