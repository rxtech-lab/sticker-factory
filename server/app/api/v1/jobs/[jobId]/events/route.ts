import { clientDocumentVersion } from "@/lib/contracts/sticker";
import { withApiAuth } from "@/lib/http/handler";
import { listGenerationEvents, serializeGenerationEvent } from "@/lib/services/events";

type Context = { params: Promise<{ jobId: string }> };
const terminal = new Set(["succeeded", "failed", "cancelled"]);

// Long-lived streaming response: declare the segment explicitly rather than relying on
// inference, and never let a cached or statically-rendered variant be served.
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const fetchCache = "force-no-store";
export const maxDuration = 60;

/** Fast polls while a turn is spinning up, then settle down for the rest of the window. */
function pollDelay(elapsedMs: number): number {
  return elapsedMs < 2_000 ? 250 : 750;
}

export async function GET(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { jobId } = await context.params;
    const url = new URL(request.url);
    const cursorValue = request.headers.get("last-event-id") ?? url.searchParams.get("after") ?? "0";
    if (!/^\d+$/.test(cursorValue)) throw new (await import("@/lib/http/errors")).ApiError(400, "INVALID_EVENT_CURSOR", "Last-Event-ID must be a non-negative integer");
    let cursor = Number(cursorValue);
    if (!Number.isSafeInteger(cursor)) throw new (await import("@/lib/http/errors")).ApiError(400, "INVALID_EVENT_CURSOR", "Last-Event-ID is too large");
    // Also proves the job exists and belongs to the caller before the stream body starts,
    // so an unknown job still produces a JSON 404 rather than an empty event stream.
    const initial = await listGenerationEvents(db, principal.sub, jobId, cursor);
    // Read once, outside the stream body: `request.headers` is still live there, but resolving it
    // per event would repeat the same parse for every frame of a turn.
    const contractVersion = clientDocumentVersion(request);
    const encoder = new TextEncoder();
    const stream = new ReadableStream<Uint8Array>({
      async start(controller) {
        const openedAt = Date.now();
        const deadline = openedAt + 25_000;
        let pending: typeof initial | undefined = initial;
        try {
          controller.enqueue(encoder.encode("retry: 1000\n\n"));
          while (!request.signal.aborted && Date.now() < deadline) {
            // The first iteration reuses the query that produced `x-job-state` instead of
            // re-running the identical read on every connect and reconnect.
            const { job, events } = pending ?? await listGenerationEvents(db, principal.sub, jobId, cursor);
            pending = undefined;
            for (const event of events) {
              const serialized = serializeGenerationEvent(event, contractVersion);
              controller.enqueue(encoder.encode(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(serialized)}\n\n`));
              cursor = event.id;
            }
            // Terminal job transitions and their terminal events are committed atomically.
            // A reconnect that has already consumed that event learns the terminal state from
            // the trailing `end` frame; manufacturing a duplicate event would violate
            // monotonic replay.
            if (terminal.has(job.state)) {
              controller.enqueue(encoder.encode(`event: end\ndata: ${JSON.stringify({ jobState: job.state })}\n\n`));
              break;
            }
            controller.enqueue(encoder.encode(`: heartbeat ${Date.now()}\n\n`));
            await new Promise((resolve) => setTimeout(resolve, pollDelay(Date.now() - openedAt)));
          }
          controller.close();
        } catch (error) {
          controller.error(error);
        }
      },
    });
    return new Response(stream, {
      headers: {
        "content-type": "text/event-stream; charset=utf-8",
        "cache-control": "private, no-cache, no-transform",
        connection: "keep-alive",
        // Frames must reach the client as they are produced; any compression or proxy
        // buffering layer here silently turns the live stream into a single blob at the end.
        "content-encoding": "identity",
        "x-accel-buffering": "no",
        "x-job-state": initial.job.state,
      },
    });
  });
}
