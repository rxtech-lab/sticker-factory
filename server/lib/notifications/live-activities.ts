import { and, desc, eq, gt, inArray, sql } from "drizzle-orm";
import { z } from "zod";
import { firstRow, type Database } from "@/lib/db/client";
import { generationEvents, generationJobs, generationLiveActivities } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getApnsConfig, sendPushes } from "@/lib/notifications/apns";

export const RegisterLiveActivitySchema = z.object({
  activityId: z.string().min(1).max(128),
  jobId: z.uuid(),
  token: z.string().regex(/^[a-f0-9]{32,512}$/),
  environment: z.enum(["sandbox", "production"]),
});

export async function registerLiveActivity(db: Database, ownerId: string, input: z.infer<typeof RegisterLiveActivitySchema>) {
  const job = await db.select().from(generationJobs)
    .where(and(eq(generationJobs.id, input.jobId), eq(generationJobs.ownerId, ownerId))).then(firstRow);
  if (!job) throw new ApiError(404, "JOB_NOT_FOUND", "Generation job not found");
  const values = { ...input, ownerId, expiresAt: new Date(Date.now() + 8 * 60 * 60 * 1000) };
  const rows = await db.insert(generationLiveActivities).values(values).onConflictDoUpdate({
    target: generationLiveActivities.activityId,
    set: {
      token: input.token, environment: input.environment,
      lastEventId: sql`CASE WHEN ${generationLiveActivities.token} = ${input.token} THEN ${generationLiveActivities.lastEventId} ELSE 0 END`,
    },
    setWhere: and(eq(generationLiveActivities.ownerId, ownerId), eq(generationLiveActivities.jobId, input.jobId)),
  }).returning({ id: generationLiveActivities.activityId });
  if (!rows.length) throw new ApiError(409, "ACTIVITY_CONFLICT", "Live Activity belongs to another generation");
}

export async function unregisterLiveActivity(db: Database, ownerId: string, activityId: string) {
  await db.delete(generationLiveActivities)
    .where(and(eq(generationLiveActivities.activityId, activityId), eq(generationLiveActivities.ownerId, ownerId)));
}

// Mirrors StickerToolLabel so foreground and pushed progress use the same wording.
const toolLabels: Record<string, string> = {
  "reply": "Writing a reply",
  "generate-sticker": "Making your sticker",
  "generate-image": "Drawing artwork",
  "generate-video": "Filming a clip",
  "edit-sticker": "Editing sticker",
  "animate-sticker": "Animating sticker",
  "plan-sticker": "Planning sticker",
  "build-plan": "Building plan",
  "show-sticker": "Showing the sticker",
  "create_plan": "Drafting a plan",
  "update_plan": "Revising the plan",
  "show_plan": "Showing the plan",
  "finalize_plan": "Finishing the plan",
  "create_animation": "Creating animation",
  "update_animation": "Adjusting animation",
  "edit_layer_animation": "Tuning a layer",
  "finalize_animation": "Finishing animation",
  "edit_layers": "Editing layers",
  "edit_image_layer": "Redrawing a layer",
  "add_image_layer": "Adding a layer",
  "create_video": "Filming a clip",
  "finalize_edit": "Finishing the edit",
  "view_plan_image": "Reviewing the plan image",
  "view_sticker": "Reviewing the sticker",
  "render_artwork": "Drawing it full size",
  "render_frames": "Drawing the frames",
  "render_attachments": "Making the send sizes",
  "render_webp": "Making the compact copy",
  "render_sizes": "Fitting it for Messages",
  "save_renditions": "Saving it"
};

function readableTool(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const [stem, ordinal] = value.split("#").map((part) => part.trim());
  const label = toolLabels[stem] ?? readableStatus(stem);
  return ordinal && label ? `${label} (${ordinal})` : label;
}

// Mirrors StickerToolLabel.stages, for the same reason as the tool labels above: a stage is what
// the Lock Screen shows during the stretches of a turn that open no tool row at all.
const stageLabels: Record<string, string> = {
  "reading_request": "Reading your request",
  "preparing_context": "Gathering references",
  "planning_edit": "Planning the edit",
  "planning_animation": "Planning the motion",
  "generating_image": "Drawing artwork",
  "reviewing": "Reviewing the design",
  "composing": "Composing the artwork",
  "composing_part": "Drawing a part",
  "composing_sprite": "Drawing the frames",
  "composing_video": "Filming a clip",
  "assembling": "Assembling the layers",
  "validating_candidate": "Checking the result",
  "rendering_exports": "Rendering the sticker",
  "verifying_exports": "Verifying the files",
  "finalizing": "Finishing up"
};

function readableStage(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  return stageLabels[value] ?? readableStatus(value);
}

function readableStatus(value: unknown): string | undefined {
  if (typeof value !== "string" || !value.trim()) return undefined;
  const words = value.trim().replaceAll("_", " ").replaceAll("-", " ");
  return (words[0].toUpperCase() + words.slice(1)).slice(0, 180);
}

/** Read the latest meaningful status, not document chunks or a completed tool's old label. */
export async function liveActivitySnapshot(db: Database, ownerId: string, jobId: string) {
  const job = await db.select().from(generationJobs)
    .where(and(eq(generationJobs.id, jobId), eq(generationJobs.ownerId, ownerId))).then(firstRow);
  if (!job) throw new ApiError(404, "JOB_NOT_FOUND", "Generation job not found");
  const event = await db.select().from(generationEvents).where(and(
    eq(generationEvents.jobId, jobId),
    inArray(generationEvents.type, ["queued", "started", "progress", "waiting", "completed", "failed"]),
    sql`(${generationEvents.type} != 'progress' OR (
      ${generationEvents.dataJson}->>'message' IS NOT NULL OR
      ${generationEvents.dataJson}->>'stage' IS NOT NULL OR
      ${generationEvents.dataJson}->>'note' IS NOT NULL OR
      ${generationEvents.dataJson}->>'completedUnits' IS NOT NULL OR
      ${generationEvents.dataJson}->>'completedParts' IS NOT NULL OR
      ${generationEvents.dataJson}->>'clearProgress' = 'true' OR
      ${generationEvents.dataJson}->>'toolStatus' = 'streaming'
    ))`,
  )).orderBy(desc(generationEvents.id)).limit(1).then(firstRow);
  const terminal = ["succeeded", "failed", "cancelled"].includes(job.state);
  const phase = job.state === "succeeded" ? "completed" : job.state === "running" ? "running" : job.state;
  // A count-only update still advances the snapshot version. Keep the most recent text
  // independently so it cannot revert to a generic status when the counter moves.
  const textEvent = !terminal && event ? await db.select({ data: generationEvents.dataJson })
    .from(generationEvents).where(and(
      eq(generationEvents.jobId, jobId),
      sql`${generationEvents.id} <= ${event.id}`,
      inArray(generationEvents.type, ["queued", "started", "progress", "waiting"]),
      sql`(${generationEvents.dataJson}->>'message' IS NOT NULL OR
        ${generationEvents.dataJson}->>'stage' IS NOT NULL OR
        ${generationEvents.dataJson}->>'note' IS NOT NULL OR
        ${generationEvents.dataJson}->>'toolStatus' = 'streaming')`,
    )).orderBy(desc(generationEvents.id)).limit(1).then(firstRow) : undefined;
  const data = textEvent?.data ?? {};
  // Tool/status events preserve the current stage count until an explicit clear or new count.
  // Bound the lookup to the status snapshot so its event ID also versions these counters.
  const progressEvent = !terminal && event
    ? await db.select({ data: generationEvents.dataJson }).from(generationEvents).where(and(
      eq(generationEvents.jobId, jobId),
      eq(generationEvents.type, "progress"),
      sql`${generationEvents.id} <= ${event.id}`,
      sql`(${generationEvents.dataJson}->>'completedUnits' IS NOT NULL
        OR ${generationEvents.dataJson}->>'completedParts' IS NOT NULL
        OR ${generationEvents.dataJson}->>'clearProgress' = 'true')`,
    )).orderBy(desc(generationEvents.id)).limit(1).then(firstRow)
    : undefined;
  const progressData = progressEvent?.data;
  const progressCounts = z.object({
    completedUnits: z.number().int().nonnegative(),
    totalUnits: z.number().int().positive(),
    progressLabel: z.string().min(1).max(60),
  }).refine((counts) => counts.completedUnits <= counts.totalUnits).safeParse(progressData?.clearProgress === true ? undefined : {
    completedUnits: progressData?.completedUnits ?? progressData?.completedParts,
    totalUnits: progressData?.totalUnits ?? progressData?.totalParts,
    progressLabel: progressData?.progressLabel ?? "Artwork parts",
  });
  const message = terminal
    ? (job.state === "succeeded" ? "Done!" : job.state === "failed" ? "Generation failed. Open to retry." : "Generation stopped")
    : readableStatus(data.note) ?? readableStatus(data.message) ?? readableStage(data.stage) ?? readableTool(data.toolName)
      ?? (job.state === "queued" ? "Waiting to start…" : job.state === "waiting" ? "Waiting for your input" : "Creating your sticker…");
  return {
    state: { message, phase, eventID: event?.id ?? 0, ...(progressCounts.success ? progressCounts.data : {}) },
    terminal,
  };
}

/** Best effort; awaited by workflow steps so the serverless runtime can finish delivery. */
export async function pushLiveActivityUpdate(db: Database, ownerId: string, jobId: string): Promise<void> {
  try {
    const config = getApnsConfig();
    if (!config) return;
    // Serialize this job's pushes, including registration catch-up, across server instances.
    // Reading after the lock prevents a late progress sender from overwriting a terminal state.
    await db.transaction(async (tx) => {
      await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext(${`live-activity:${jobId}`}))`);
      const activities = await tx.select().from(generationLiveActivities).where(and(
        eq(generationLiveActivities.jobId, jobId), eq(generationLiveActivities.ownerId, ownerId),
        gt(generationLiveActivities.expiresAt, new Date()),
      ));
      if (!activities.length) return;
      const snapshot = await liveActivitySnapshot(tx, ownerId, jobId);
      for (const activity of activities) {
        if (snapshot.state.eventID <= activity.lastEventId) continue;
        const timestamp = Math.max(Math.floor(Date.now() / 1000), activity.lastPushTimestamp + 1);
        const [result] = await sendPushes([{
          token: activity.token, environment: activity.environment,
          pushType: "liveactivity", priority: snapshot.terminal ? "10" : "5",
          collapseId: `live-${jobId}`,
          payload: { aps: {
            timestamp, event: snapshot.terminal ? "end" : "update",
            "content-state": snapshot.state,
            // Keep the final state on the Lock Screen using the system's default retention.
            ...(!snapshot.terminal ? { "stale-date": timestamp + 180 } : {}),
          } },
        }], config);
        if (result?.permanentlyGone) {
          await tx.delete(generationLiveActivities).where(eq(generationLiveActivities.activityId, activity.activityId));
        } else if (result?.ok) {
          await tx.update(generationLiveActivities).set({ lastEventId: snapshot.state.eventID, lastPushTimestamp: timestamp })
            .where(eq(generationLiveActivities.activityId, activity.activityId));
        }
      }
    });
  } catch {
    // Never include activity tokens or generation text in logs.
    console.warn("[live-activity] Update could not be delivered", { jobId });
  }
}
