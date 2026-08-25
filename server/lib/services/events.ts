import { and, asc, eq, gt } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { generationEvents, generationJobs } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

export type GenerationEventType = typeof generationEvents.$inferInsert.type;

export async function appendGenerationEvent(
  db: Database,
  jobId: string,
  ownerId: string,
  type: GenerationEventType,
  data: Record<string, unknown>,
) {
  const [event] = await db.insert(generationEvents).values({
    jobId,
    ownerId,
    type,
    dataJson: data,
    createdAt: new Date(),
  }).returning();
  return event;
}

export async function listGenerationEvents(db: Database, ownerId: string, jobId: string, afterId = 0, limit = 200) {
  const job = await db.select().from(generationJobs)
    .where(and(eq(generationJobs.id, jobId), eq(generationJobs.ownerId, ownerId))).get();
  if (!job) throw new ApiError(404, "JOB_NOT_FOUND", "Generation job not found");
  const events = await db.select().from(generationEvents)
    .where(and(
      eq(generationEvents.jobId, jobId),
      eq(generationEvents.ownerId, ownerId),
      gt(generationEvents.id, afterId),
    ))
    .orderBy(asc(generationEvents.id)).limit(Math.min(Math.max(limit, 1), 200));
  return { job, events };
}

export function serializeGenerationEvent(event: typeof generationEvents.$inferSelect) {
  return {
    id: event.id,
    jobId: event.jobId,
    type: event.type,
    createdAt: event.createdAt.toISOString(),
    data: event.dataJson,
  };
}
