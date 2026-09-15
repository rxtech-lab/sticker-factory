// Durable retry context shared by the Retry button and conversational recovery.
import { and, asc, desc, eq, inArray, ne, sql } from "drizzle-orm";
import type { AiChatAction, AiRetryableGeneration } from "@/lib/ai/gateway-contracts";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, generationEvents, generationJobs, type GenerationJobRow } from "@/lib/db/schema";

const AI_KINDS = ["image", "edit", "animation", "chat", "plan", "compose"] as const;

/** Keep the new attempt's identity, but execute the original request and its saved route. */
export async function generationExecutionContext(db: Database, attempt: GenerationJobRow) {
  let original = attempt;
  const seen = new Set<string>();
  let retryStepId: string | undefined;
  while (!seen.has(original.id)) {
    seen.add(original.id);
    const events = await db.select().from(generationEvents).where(and(
      eq(generationEvents.jobId, original.id), eq(generationEvents.ownerId, attempt.ownerId),
      eq(generationEvents.type, "queued"),
    )).orderBy(desc(generationEvents.id));
    const retryEvent = events.find((event) => typeof event.dataJson.retryOfJobId === "string");
    const retryOfJobId = retryEvent?.dataJson.retryOfJobId;
    if (!retryStepId && typeof retryEvent?.dataJson.retryStepId === "string") retryStepId = retryEvent.dataJson.retryStepId;
    if (typeof retryOfJobId !== "string") break;
    const previous = await db.select().from(generationJobs).where(and(
      eq(generationJobs.id, retryOfJobId), eq(generationJobs.ownerId, attempt.ownerId),
      eq(generationJobs.stickerId, attempt.stickerId), inArray(generationJobs.kind, [...AI_KINDS]),
    )).then(firstRow);
    if (!previous) throw new Error("The original generation is no longer available");
    original = previous;
  }
  const events = original.kind === "chat" ? await db.select().from(generationEvents).where(and(
    eq(generationEvents.jobId, original.id), eq(generationEvents.ownerId, attempt.ownerId),
    eq(generationEvents.type, "progress"), sql`${generationEvents.dataJson}->>'checkpoint' = 'routed_chat'`,
  )).orderBy(desc(generationEvents.id)).limit(1) : [];
  const routedAction = events.find((event) => event.dataJson.checkpoint === "routed_chat")?.dataJson.action as AiChatAction | undefined;
  return { original, routedAction, attemptIds: [...seen], retryStepId };
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
    const { original, attemptIds } = await generationExecutionContext(db, previous);
    if (!original.sourceMessageId) return undefined;
    const source = await db.select().from(chatMessages).where(and(
      eq(chatMessages.id, original.sourceMessageId), eq(chatMessages.ownerId, current.ownerId),
    )).then(firstRow);
    if (!source) return undefined;
    const steps = await db.select().from(chatMessages).where(and(
      inArray(chatMessages.jobId, attemptIds),
      eq(chatMessages.ownerId, current.ownerId), eq(chatMessages.role, "system"), eq(chatMessages.kind, "status"),
    )).orderBy(asc(chatMessages.sequence));
    return {
      jobId: previous.id, kind: original.kind, instruction: source.content,
      state: previous.state, error: previous.errorMessage ?? undefined,
      // Carry stages across attempts, with the latest outcome winning for a repeated stage.
      steps: [...new Map(steps.map((step) => [step.content, step])).values()]
        .map((step) => ({ id: step.id, name: step.content, status: step.status })),
    };
  }
}
