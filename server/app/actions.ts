"use server";

import { redirect } from "next/navigation";
import { signIn, signOut } from "@/lib/auth/web";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { executeIdempotent } from "@/lib/services/idempotency";
import { createCleanupJob } from "@/lib/services/stickers";
import { startCleanupWorkflow } from "@/lib/services/workflows";

export async function signInAction() {
  await signIn("rxlab", { redirectTo: "/library" });
}

export async function signOutAction() {
  await signOut({ redirectTo: "/" });
}

export async function deleteStickerAction(formData: FormData) {
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");
  const stickerId = String(formData.get("stickerId") ?? "");
  const idempotencyKey = String(formData.get("idempotencyKey") ?? "");
  if (!stickerId || !idempotencyKey) throw new Error("Invalid deletion request");
  const db = getDatabase();
  await executeIdempotent(db, {
    ownerId,
    operation: `delete-sticker:${stickerId}`,
    key: idempotencyKey,
    request: { stickerId },
  }, async () => {
    const jobId = await createCleanupJob(db, ownerId, stickerId);
    const workflowRunId = await startCleanupWorkflow(db, jobId);
    return { status: 202, body: { stickerId, jobId, workflowRunId } };
  });
  redirect("/library");
}
