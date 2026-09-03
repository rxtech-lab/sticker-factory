"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { signIn, signOut } from "@/lib/auth/web";
import { getHealthyWebSession } from "@/lib/auth/session";
import { getDatabase } from "@/lib/db/client";
import { executeIdempotent } from "@/lib/services/idempotency";
import {
  addPackItem,
  createPack,
  deletePack,
  getPack,
  installPack,
  publishPack,
  removePackItem,
  reorderPackItems,
  uninstallPack,
  unpublishPack,
  updatePack,
} from "@/lib/services/packs";
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
  const db = await getDatabase();
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

// ---------------------------------------------------------------------------
// Marketplace
//
// The web uses server actions rather than the REST routes for its own CRUD, but shares the same
// service layer and the same `executeIdempotent` wrapper — so a double-submitted form and a
// retried API call collapse to the same single effect.
// ---------------------------------------------------------------------------

/** The signed-in owner, plus the hidden per-render idempotency key the forms all carry. */
async function packFormContext(formData: FormData) {
  const session = await getHealthyWebSession();
  const ownerId = session?.user?.id;
  if (!ownerId) redirect("/login");
  const idempotencyKey = String(formData.get("idempotencyKey") ?? "");
  if (!idempotencyKey) throw new Error("Invalid pack request");
  return { ownerId, idempotencyKey, db: await getDatabase() };
}

function requiredField(formData: FormData, name: string): string {
  const value = String(formData.get(name) ?? "").trim();
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

/** Every surface that can show a pack, so an edit is never left showing a stale copy. */
function revalidatePack(slug?: string) {
  revalidatePath("/marketplace");
  revalidatePath("/library");
  if (slug) {
    revalidatePath(`/marketplace/${slug}`);
    revalidatePath(`/marketplace/${slug}/edit`);
  }
}

export async function createPackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const title = requiredField(formData, "title");
  const summary = String(formData.get("summary") ?? "").trim();
  const stickerIds = formData.getAll("stickerIds").map(String).filter(Boolean);
  const created = await executeIdempotent(db, {
    ownerId,
    operation: "create-pack",
    key: idempotencyKey,
    request: { title, summary, stickerIds },
  }, async () => ({
    status: 201,
    body: await createPack(db, ownerId, { title, summary: summary || null, stickerIds }),
  }));
  revalidatePack();
  redirect(`/marketplace/${(created.body as { slug: string }).slug}/edit`);
}

export async function updatePackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const title = requiredField(formData, "title");
  const summary = String(formData.get("summary") ?? "").trim();
  const updated = await executeIdempotent(db, {
    ownerId,
    operation: `update-pack:${packId}`,
    key: idempotencyKey,
    request: { title, summary },
  }, async () => ({
    status: 200,
    body: await updatePack(db, ownerId, packId, { title, summary: summary || null }),
  }));
  revalidatePack((updated.body as { slug: string }).slug);
  redirect(`/marketplace/${(updated.body as { slug: string }).slug}/edit`);
}

export async function publishPackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const published = await executeIdempotent(db, {
    ownerId,
    operation: `publish-pack:${packId}`,
    key: idempotencyKey,
    request: { packId },
  }, async () => ({ status: 200, body: await publishPack(db, ownerId, packId) }));
  revalidatePack((published.body as { slug: string }).slug);
  redirect(`/marketplace/${(published.body as { slug: string }).slug}`);
}

export async function unpublishPackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const raw = String(formData.get("state") ?? "draft");
  const state = raw === "unlisted" ? "unlisted" : "draft";
  const result = await executeIdempotent(db, {
    ownerId,
    operation: `unpublish-pack:${packId}`,
    key: idempotencyKey,
    request: { packId, state },
  }, async () => ({ status: 200, body: await unpublishPack(db, ownerId, packId, state) }));
  revalidatePack((result.body as { slug: string }).slug);
  redirect(`/marketplace/${(result.body as { slug: string }).slug}/edit`);
}

export async function deletePackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  await executeIdempotent(db, {
    ownerId,
    operation: `delete-pack:${packId}`,
    key: idempotencyKey,
    request: { packId },
  }, async () => ({ status: 200, body: await deletePack(db, ownerId, packId) }));
  revalidatePack();
  redirect("/marketplace?mine=true");
}

export async function addPackItemAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const stickerId = requiredField(formData, "stickerId");
  const result = await executeIdempotent(db, {
    ownerId,
    operation: `add-pack-item:${packId}`,
    key: idempotencyKey,
    request: { packId, stickerId },
  }, async () => ({ status: 200, body: await addPackItem(db, ownerId, packId, stickerId) }));
  revalidatePack((result.body as { slug: string }).slug);
  redirect(`/marketplace/${(result.body as { slug: string }).slug}/edit`);
}

export async function removePackItemAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const stickerId = requiredField(formData, "stickerId");
  const result = await executeIdempotent(db, {
    ownerId,
    operation: `remove-pack-item:${packId}:${stickerId}`,
    key: idempotencyKey,
    request: { packId, stickerId },
  }, async () => ({ status: 200, body: await removePackItem(db, ownerId, packId, stickerId) }));
  revalidatePack((result.body as { slug: string }).slug);
  redirect(`/marketplace/${(result.body as { slug: string }).slug}/edit`);
}

/**
 * Move one member up or down.
 *
 * The order is read fresh and re-sent whole, so two people reordering the same pack cannot
 * interleave into an order neither of them chose.
 */
export async function movePackItemAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const stickerId = requiredField(formData, "stickerId");
  const direction = String(formData.get("direction") ?? "up") === "down" ? 1 : -1;

  const pack = await getPack(db, ownerId, packId);
  const order = pack.stickers.map((sticker) => sticker.id);
  const from = order.indexOf(stickerId);
  const to = from + direction;
  if (from === -1 || to < 0 || to >= order.length) {
    redirect(`/marketplace/${pack.slug}/edit`);
  }
  order.splice(to, 0, ...order.splice(from, 1));

  await executeIdempotent(db, {
    ownerId,
    operation: `set-pack-items:${packId}`,
    key: idempotencyKey,
    request: { stickerIds: order },
  }, async () => ({ status: 200, body: await reorderPackItems(db, ownerId, packId, order) }));
  revalidatePack(pack.slug);
  redirect(`/marketplace/${pack.slug}/edit`);
}

export async function installPackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const slug = String(formData.get("slug") ?? "");
  await executeIdempotent(db, {
    ownerId,
    operation: `install-pack:${packId}`,
    key: idempotencyKey,
    request: { packId },
  }, async () => ({ status: 200, body: await installPack(db, ownerId, packId) }));
  revalidatePack(slug || undefined);
  redirect(`/marketplace/${slug || packId}`);
}

export async function uninstallPackAction(formData: FormData) {
  const { ownerId, idempotencyKey, db } = await packFormContext(formData);
  const packId = requiredField(formData, "packId");
  const slug = String(formData.get("slug") ?? "");
  await executeIdempotent(db, {
    ownerId,
    operation: `uninstall-pack:${packId}`,
    key: idempotencyKey,
    request: { packId },
  }, async () => ({ status: 200, body: await uninstallPack(db, ownerId, packId) }));
  revalidatePack(slug || undefined);
  redirect(`/marketplace/${slug || packId}`);
}
