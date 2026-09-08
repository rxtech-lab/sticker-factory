import { after } from "next/server";
import { PublishExportsRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { publishExports } from "@/lib/services/export-publish";
import { executeIdempotent, requireIdempotencyKey } from "@/lib/services/idempotency";
import { createExportJob } from "@/lib/services/stickers";
import { startExportWorkflow } from "@/lib/services/workflows";
import { exportCreditCost } from "@/lib/subscription/pricing";

type Context = { params: Promise<{ id: string }> };

/**
 * Binds an already-rendered export set onto the sticker, here in this request.
 *
 * Everything this needs is done by the time it is called: the app drew every rendition, uploaded
 * them, and each one was verified as it landed. What is left — see `publishExports` — is a bind
 * against the database, which is why it no longer goes near the durable runtime. The job row and
 * its event stream stay exactly as they were, so the client watches this publish the same way it
 * watches a generation; it simply finds the job already finished when it connects.
 *
 * The response still says 202 and still carries a job. That is not a fiction kept for the sake of
 * the contract: a bind that fails on something transient hands the job to the workflow after all,
 * and the state field is where the client is told which of the two happened.
 */
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const body = await readJson(request, PublishExportsRequestSchema.parse);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation: `exports:${id}`, key: requireIdempotencyKey(request), request: body }, async () => {
      const jobId = await createExportJob(db, principal.sub, id, exportCreditCost(body));
      // Settled after the response flushes. It is a call to the billing service, the job is already
      // terminal in the database by the time it runs, and nothing the client does next depends on
      // it — so putting it on the wire ahead of the response would be spending the user's wait on
      // bookkeeping.
      const outcome = await publishExports(db, jobId, body, { settlement: after });
      let workflowRunId: string | null = null;
      let state: "queued" | "succeeded" | "failed";
      let retryable = false;
      if ("deferToWorkflow" in outcome) {
        state = "queued";
        try {
          workflowRunId = await startExportWorkflow(db, jobId, body);
        } catch {
          state = "failed";
          retryable = true;
        }
      } else {
        state = outcome.state;
        retryable = outcome.retryable;
      }
      return { status: 202, body: { job: { id: jobId, state, workflowRunId, retryable, eventsUrl: `/api/v1/jobs/${jobId}/events` } } };
    });
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
