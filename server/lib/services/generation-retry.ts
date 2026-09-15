// Durable retry context shared by the Retry button and conversational recovery.
import { and, asc, desc, eq, inArray, ne } from "drizzle-orm";
import type { AiChatAction, AiRetryableGeneration } from "@/lib/ai/gateway-contracts";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, generationEvents, generationJobs, type GenerationJobRow } from "@/lib/db/schema";

const AI_KINDS = ["image", "edit", "animation", "chat", "plan", "compose"] as const;

/** Keep the new attempt's identity, but execute the original request and its saved route. */
export async function generationExecutionContext(db: Database, attempt: GenerationJobRow) {
  let original = attempt;
  const seen = new Set<string>();
  while (!seen.has(original.id)) {
    seen.add(original.id);
    const events = await db.select().from(generationEvents).where(and(
      eq(generationEvents.jobId, original.id), eq(generationEvents.ownerId, attempt.ownerId),
      eq(generationEvents.type, "queued"),
    )).orderBy(desc(generationEvents.id));
    const retryOfJobId = events.find((event) => typeof event.dataJson.retryOfJobId === "string")?.dataJson.retryOfJobId;
    if (typeof retryOfJobId !== "string") break;
    const previous = await db.select().from(generationJobs).where(and(
      eq(generationJobs.id, retryOfJobId), eq(generationJobs.ownerId, attempt.ownerId),
      eq(generationJobs.stickerId, attempt.stickerId), inArray(generationJobs.kind, [...AI_KINDS]),
    )).then(firstRow);
    if (!previous) throw new Error("The original generation is no longer available");
    original = previous;
  }
  const events = await db.select().from(generationEvents).where(and(
    eq(generationEvents.jobId, original.id), eq(generationEvents.ownerId, attempt.ownerId),
    eq(generationEvents.type, "progress"),
  )).orderBy(desc(generationEvents.id));
  const routedAction = events.find((event) => event.dataJson.stage === "routed_chat")?.dataJson.action as AiChatAction | undefined;
  return { original, routedAction };
}

/** Questions after a failure may be skipped; a newer successful generation supersedes it. */
export async function latestRetryableGeneration(db: Database, current: GenerationJobRow): Promise<AiRetryableGeneration | undefined> {
  const previousJobs = await db.select().from(generationJobs).where(and(
    eq(generationJobs.ownerId, current.ownerId), eq(generationJobs.stickerId, current.stickerId),
    ne(generationJobs.id, current.id), inArray(generationJobs.kind, [...AI_KINDS]),
  )).orderBy(desc(generationJobs.createdAt), desc(generationJobs.id)).limit(30);
  for (const previous of previousJobs) {
    if (previous.state === "succeeded") {
      const result = await db.select().from(chatMessages).where(and(
        eq(chatMessages.jobId, previous.id), eq(chatMessages.role, "assistant"),
      )).then(firstRow);
      if (result && !result.revisionId && !result.planId && result.kind === "text") continue;
      return undefined;
    }
    if (previous.state !== "failed" && previous.state !== "cancelled") return undefined;
    const { original } = await generationExecutionContext(db, previous);
    if (!original.sourceMessageId) return undefined;
    const source = await db.select().from(chatMessages).where(and(
      eq(chatMessages.id, original.sourceMessageId), eq(chatMessages.ownerId, current.ownerId),
    )).then(firstRow);
    if (!source) return undefined;
    const steps = await db.select().from(chatMessages).where(and(
      inArray(chatMessages.jobId, [...new Set([previous.id, original.id])]),
      eq(chatMessages.ownerId, current.ownerId), eq(chatMessages.role, "system"), eq(chatMessages.kind, "status"),
    )).orderBy(asc(chatMessages.sequence));
    return {
      jobId: previous.id, kind: original.kind, instruction: source.content,
      state: previous.state, error: previous.errorMessage ?? undefined,
      steps: steps.map((step) => ({ id: step.id, name: step.content, status: step.status })),
    };
  }
}
