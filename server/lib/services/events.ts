import { and, asc, eq, gt } from "drizzle-orm";
import {
  CURRENT_DOCUMENT_VERSION,
  downcastForClient,
  StickerDocumentSchema,
} from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { generationEvents, generationJobs } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";

import { pushLiveActivityUpdate } from "@/lib/notifications/live-activities";

export type GenerationEventType = typeof generationEvents.$inferInsert.type;

/**
 * @param options.pushLiveActivity Pass `false` for an event that changes nothing the Lock Screen
 * shows. A Live Activity push is rate-limited by the system, so spending one on a counter only the
 * open app draws costs the next real status change its delivery.
 */
export async function appendGenerationEvent(
  db: Database,
  jobId: string,
  ownerId: string,
  type: GenerationEventType,
  data: Record<string, unknown>,
  options: { pushLiveActivity?: boolean } = {},
) {
  const [event] = await db.insert(generationEvents).values({
    jobId,
    ownerId,
    type,
    dataJson: data,
    createdAt: new Date(),
  }).returning();
  if (options.pushLiveActivity !== false && ["progress", "waiting", "completed", "failed"].includes(type)) {
    await pushLiveActivityUpdate(db, ownerId, jobId);
  }
  return event;
}

export async function listGenerationEvents(db: Database, ownerId: string, jobId: string, afterId = 0, limit = 200) {
  const job = await db.select().from(generationJobs)
    .where(and(eq(generationJobs.id, jobId), eq(generationJobs.ownerId, ownerId))).then(firstRow);
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

/**
 * @param clientVersion The document contract the reader announced. `document` and `candidate`
 * payloads carry a whole `StickerDocument`, so this is a client-facing read seam exactly like
 * `getSticker` and has to degrade the same way — a v3 layer streamed to a v2 client would fail the
 * decode of the event, and with it the turn the user is watching.
 */
export function serializeGenerationEvent(
  event: typeof generationEvents.$inferSelect,
  clientVersion: number = CURRENT_DOCUMENT_VERSION,
) {
  return {
    id: event.id,
    jobId: event.jobId,
    type: event.type,
    createdAt: event.createdAt.toISOString(),
    data: downcastEventData(event.dataJson, clientVersion),
  };
}

/**
 * Rewrites an event payload's embedded document, if it has one.
 *
 * Parsing through `StickerDocumentSchema` rather than reaching into the raw JSON, because stored
 * payloads may hold a document from any version this table has ever seen and the downcast is
 * defined over the current shape. A payload whose document does not parse is passed through
 * untouched: this is a streaming read on a live turn, and dropping the event the user is waiting on
 * would be worse than sending one an old client might not draw.
 */
function downcastEventData(data: unknown, clientVersion: number): unknown {
  if (clientVersion >= CURRENT_DOCUMENT_VERSION) return data;
  if (!data || typeof data !== "object" || !("document" in data)) return data;
  const parsed = StickerDocumentSchema.safeParse((data as { document: unknown }).document);
  if (!parsed.success) return data;
  return { ...data, document: downcastForClient(parsed.data, clientVersion) };
}
