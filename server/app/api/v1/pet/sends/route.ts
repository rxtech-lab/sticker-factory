import { after } from "next/server";
import { RecordPetSendRequestSchema } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { recordPetSend } from "@/lib/services/pets";

/**
 * A sticker the caller just sent to someone. The pet reads it after the response is out, so the
 * Messages extension is never kept waiting on a model; the new pose shows on the next `GET /pet`.
 *
 * Not idempotency-keyed: a repeated send of the same sticker inside the service's window is already
 * folded into the first.
 */
export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, RecordPetSendRequestSchema.parse);
    return noStoreJson(await recordPetSend(db, principal.sub, body, (task) => after(task)), { status: 202 });
  });
}
