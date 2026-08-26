import { PublishExportsRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createExportJob } from "@/lib/services/stickers";
import { startExportWorkflow } from "@/lib/services/workflows";

type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const body = await readJson(request, PublishExportsRequestSchema.parse);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation: `exports:${id}`, key: requireIdempotencyKey(request), request: body }, async () => {
      const jobId = await createExportJob(db, principal.sub, id);
      let workflowRunId: string | null = null;
      let state: "queued" | "failed" = "queued";
      try {
        workflowRunId = await startExportWorkflow(db, jobId, body);
      } catch {
        state = "failed";
      }
      return { status: 202, body: { job: { id: jobId, state, workflowRunId, retryable: state === "failed", eventsUrl: `/api/v1/jobs/${jobId}/events` } } };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
