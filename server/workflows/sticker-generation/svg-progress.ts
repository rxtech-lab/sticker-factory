import type { SVGAuthoringProgress } from "@/lib/ai/gateway-svg";
import { eq } from "drizzle-orm";
import { getDatabase } from "@/lib/db/client";
import { chatMessages, type GenerationJobRow } from "@/lib/db/schema";
import { appendGenerationEvent } from "@/lib/services/events";
import { assertJobStillRunning, beginToolCall, finishToolCall } from "./turn-context";

const stages = {
  authoring: { tool: "create_svg", stage: "authoring_svg", title: "Drawing SVG artwork", done: "SVG artwork drawn." },
  validation: { tool: "validate_svg", stage: "validating_svg", title: "Checking SVG animation", done: "SVG structure and animation checks passed." },
  review: { tool: "review_svg", stage: "reviewing_svg", title: "Reviewing SVG artwork", done: "SVG artwork matches the reference." },
} as const;

/** Uses the normal transcript and event stream, so attempts survive reconnects and app restarts. */
export function svgProgressReporter(job: GenerationJobRow, layer: { layerId: string; name: string }) {
  const calls = new Map<string, string>();
  let attemptOffset: number | undefined;
  return async (event: SVGAuthoringProgress) => {
    const db = await getDatabase();
    if (attemptOffset === undefined) {
      const previous = (await db.select().from(chatMessages).where(eq(chatMessages.jobId, job.id)))
        .filter(row => row.role === "system" && row.kind === "status"
          && Object.values(stages).some(s => row.content.startsWith(`${s.tool} `))
          && row.content.includes(` [${layer.layerId}] #`));
      attemptOffset = Math.max(0, ...previous.map(row => Number(row.content.match(/ #(\d+)$/)?.[1] ?? 0)));
      for (const row of previous.filter(row => row.status === "streaming")) await finishToolCall(job, row.id, "failed", {
        engine: "svg", message: "This SVG attempt was interrupted.", correction: "Generation has resumed using the saved reference.",
      });
    }
    const attempt = event.attempt + attemptOffset, maxAttempts = event.maxAttempts + attemptOffset;
    const phase = stages[event.stage];
    // Layer ID makes labels unique even when two characters share the same display name.
    const label = `${phase.tool} ${layer.name} [${layer.layerId}] #${attempt}`;
    const key = `${event.stage}:${event.attempt}`;
    const retrying = event.status === "failed" && event.attempt < event.maxAttempts;
    const details = {
      engine: "svg", stage: event.stage, attempt, maxAttempts,
      durationMs: event.durationMs, layerId: layer.layerId, partName: layer.name,
      ...(event.errorType ? { errorType: event.errorType } : {}),
      message: event.message ?? (event.status === "complete" ? phase.done : `${phase.title}…`),
      ...(event.status === "failed" ? { correction: retrying
        ? `Trying again with the same reference (attempt ${attempt + 1} of ${maxAttempts}).`
        : "Retry generation to try this SVG step again using the saved reference." } : {}),
    };
    if (event.status === "started") {
      await assertJobStillRunning(job.id);
      const id = await beginToolCall(job, "build-plan", undefined, label);
      calls.set(key, id);
      await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
        stage: phase.stage, message: `${phase.title} for ${layer.name}…`,
        note: `Attempt ${attempt} of ${maxAttempts}`,
        toolCallId: id, toolName: label, toolStatus: "streaming", toolDetails: JSON.stringify(details),
        engine: "svg", attempt: event.attempt,
      });
    } else {
      await finishToolCall(job, calls.get(key), event.status, details);
      if (event.status === "failed") await appendGenerationEvent(db, job.id, job.ownerId, "progress", {
        stage: retrying ? "retrying_svg" : "svg_failed",
        message: retrying ? "Refining the SVG animation…" : "SVG animation needs another attempt",
        note: `${details.message} ${details.correction}`, engine: "svg", attempt: event.attempt,
      });
    }
  };
}
