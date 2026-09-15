import { clientDocumentVersion } from "@/lib/contracts/sticker";
import { SaveEditedDocumentRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { executeIdempotent, idempotencyUuid, requireIdempotencyKey } from "@/lib/services/idempotency";
import { saveEditedRevision } from "@/lib/services/stickers";

/**
 * Saves a document edited on the client as a new, already-accepted revision.
 *
 * The idempotency key does double duty here, which matters more than usual because the body is a
 * whole document: it guards the request the normal way, and `idempotencyUuid` derives the new
 * revision's id from it, so a retry after a dropped response replays the same row rather than
 * forking the revision chain.
 *
 * The response is deliberately small. `executeIdempotent` stores it verbatim in the key's row, and
 * echoing the document back would put a second copy of it in the database for 24 hours.
 */
type Context = { params: Promise<{ id: string }> };
export async function POST(request: Request, context: Context) {
  return withApiAuth(request, async (principal, db) => {
    const { id } = await context.params;
    const operation = `edit:${id}`;
    const key = requireIdempotencyKey(request);
    const body = await readJson(request, SaveEditedDocumentRequestSchema.parse);
    const result = await executeIdempotent(db, { ownerId: principal.sub, operation, key, request: body }, async () => ({
      status: 201,
      body: await saveEditedRevision(db, principal.sub, id, body, idempotencyUuid(principal.sub, operation, key), clientDocumentVersion(request)),
    }));
    return noStoreJson(result.body, { status: result.status, headers: { "idempotency-replayed": String(result.replayed) } });
  });
}
