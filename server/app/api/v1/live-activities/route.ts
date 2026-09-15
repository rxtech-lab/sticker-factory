import { after } from "next/server";
import { z } from "zod";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import {
  RegisterLiveActivitySchema, registerLiveActivity, unregisterLiveActivity,
  liveActivitySnapshot, pushLiveActivityUpdate,
} from "@/lib/notifications/live-activities";

export async function GET(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const jobId = z.uuid().parse(new URL(request.url).searchParams.get("jobId"));
    return noStoreJson(await liveActivitySnapshot(db, principal.sub, jobId));
  });
}

export async function POST(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, RegisterLiveActivitySchema.parse);
    await registerLiveActivity(db, principal.sub, body);
    // Catch up even when the job finished before ActivityKit issued its push token.
    const snapshot = await liveActivitySnapshot(db, principal.sub, body.jobId);
    after(() => pushLiveActivityUpdate(db, principal.sub, body.jobId));
    return noStoreJson(snapshot);
  });
}

export async function DELETE(request: Request) {
  return withApiAuth(request, async (principal, db) => {
    const body = await readJson(request, z.object({ activityId: z.string().min(1).max(128) }).parse);
    await unregisterLiveActivity(db, principal.sub, body.activityId);
    return noStoreJson({});
  });
}
