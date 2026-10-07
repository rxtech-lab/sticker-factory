// Fixtures and provider stubs shared by the `workflow*.test.ts` suites, which are one story
// told in three files: motion, composition, and the context an agent is given.

import { expect } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { setAiProviderForTests, type AiProvider } from "@/lib/ai/gateway";
import { setDatabaseForTests } from "@/lib/db/client";
import { assets, plans as planRows, users } from "@/lib/db/schema";
import { cancelPlan } from "@/lib/services/plans";
import { acceptRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

/** Undoes the process-wide test doubles a workflow test installs. */
export function resetWorkflowTestState() {
  setDatabaseForTests(undefined);
  setObjectStoreForTests(undefined);
  setAiProviderForTests(undefined);
}

/**
 * Base for a provider stub: every method fails loudly, so a test only spells out the calls its own
 * path makes and an unexpected one is a failure rather than a silent default.
 */
export const unusedAiProvider: AiProvider = {
  // Reference selection is a background orchestration step on every image path. Focused tests can
  // override it to inspect or narrow candidates; other stubs preserve the legacy all-reference path.
  selectImageReferences: async (input) => input.candidates.map((_, index) => index),
  generateStickerImage: () => { throw new Error("Unexpected generateStickerImage"); },
  inspectSpriteSheet: () => { throw new Error("Unexpected inspectSpriteSheet"); },
  planSticker: () => { throw new Error("Unexpected planSticker"); },
  generateConceptImage: () => { throw new Error("Unexpected generateConceptImage"); },
  generateStickerVideo: () => { throw new Error("Unexpected generateStickerVideo"); },
  refineStickerLayout: () => { throw new Error("Unexpected refineStickerLayout"); },
  animateSticker: () => { throw new Error("Unexpected animateSticker"); },
  editSticker: () => { throw new Error("Unexpected editSticker"); },
  routeChatTurn: () => { throw new Error("Unexpected routeChatTurn"); },
  showSticker: () => { throw new Error("Unexpected showSticker"); },
  reply: () => { throw new Error("Unexpected reply"); },
  // The exception to the rule above: every successful turn ends by naming the sticker, so a stub
  // that threw here would only prove the naming step swallows its errors. Keeping the current name
  // is a real provider answer, and it leaves each test's own title assertions alone.
  summarizeStickerTitle: async ({ currentTitle }) => currentTitle,
  choosePetStatus: () => { throw new Error("Unexpected choosePetStatus"); },
  generatePetActions: () => { throw new Error("Unexpected generatePetActions"); },
  generatePetItems: () => { throw new Error("Unexpected generatePetItems"); },
  generatePetRooms: () => { throw new Error("Unexpected generatePetRooms"); },
  generatePetRoomArt: () => { throw new Error("Unexpected generatePetRoomArt"); },
  discoverPetThemes: () => { throw new Error("Unexpected discoverPetThemes"); },
  choosePetTheme: () => { throw new Error("Unexpected choosePetTheme"); },
  generatePetThemeArt: () => { throw new Error("Unexpected generatePetThemeArt"); },
  respondToPetInteraction: () => { throw new Error("Unexpected respondToPetInteraction"); },
  decideForPet: () => { throw new Error("Unexpected decideForPet"); },
  reactToPetPhoto: () => { throw new Error("Unexpected reactToPetPhoto"); },
  reactToPetSharedContent: () => { throw new Error("Unexpected reactToPetSharedContent"); },
  decidePetPose: () => { throw new Error("Unexpected decidePetPose"); },
  // Pet background reads fall back on failure — a persona to a balanced explorer, headlines to the
  // last ones — so a stub that throws here leaves a test's own pet assertions alone.
  generatePetPersona: () => { throw new Error("Unexpected generatePetPersona"); },
  searchPetHeadlines: () => { throw new Error("Unexpected searchPetHeadlines"); },
  narratePetEvent: () => { throw new Error("Unexpected narratePetEvent"); },
  generatePetEncounter: () => { throw new Error("Unexpected generatePetEncounter"); },
  meetPetFriend: () => { throw new Error("Unexpected meetPetFriend"); },
  // Every finished turn shows the owner's pet the new sticker; the step swallows a failure.
  noticePetSticker: () => { throw new Error("Unexpected noticePetSticker"); },
  // Memory runs in the background and never fails what the owner waits on, so these surface only in logs.
  embedPetMemories: () => { throw new Error("Unexpected embedPetMemories"); },
  updatePetMemory: () => { throw new Error("Unexpected updatePetMemory"); },
};

/**
 * Draws an animated project's first revision as one flat `hero` layer.
 *
 * An animated project that has never been planned is planned rather than drawn, so this is the
 * whole of the route a user has to a single-image base: the first prompt drafts a plan, they turn
 * it down, and the next prompt draws. The animation tests below want that base — a document with
 * one layer to keyframe — not the composition a confirmed plan would have built.
 */
export async function drawnAnimatedBase(
  db: Awaited<ReturnType<typeof createTestDatabase>>["db"],
  ownerId: string,
  stickerId: string,
  text: string,
) {
  const planTurn = await createChatTurn(db, ownerId, stickerId, {
    text, intent: "generate", attachments: [], imagePlacement: "replace",
  });
  expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");
  const [plan] = await db.select().from(planRows).where(eq(planRows.stickerId, stickerId));
  // No reason given, so the plan is simply dropped rather than queueing a re-planning turn.
  await cancelPlan(db, ownerId, stickerId, plan.id);
  return createChatTurn(db, ownerId, stickerId, {
    text, intent: "generate", attachments: [], imagePlacement: "replace",
  });
}

/** An animated sticker with one accepted base revision, ready for an animate turn. */
export async function animatedStickerWithAcceptedBase(db: Awaited<ReturnType<typeof createTestDatabase>>["db"], ownerId: string) {
  await db.insert(users).values({ id: ownerId, createdAt: new Date(), updatedAt: new Date() });
  const sticker = await createSticker(db, ownerId, { title: "Loop", kind: "animated", prompt: "Loop", referenceAssetIds: [] });
  const baseTurn = await drawnAnimatedBase(db, ownerId, sticker.stickerId, "Loop");
  await stickerGenerationWorkflow(baseTurn.jobId);
  await acceptRevision(db, ownerId, sticker.stickerId, baseTurn.jobId);
  return { stickerId: sticker.stickerId, baseRevisionId: baseTurn.jobId };
}

export const animateTurnOn = (db: Awaited<ReturnType<typeof createTestDatabase>>["db"], ownerId: string, stickerId: string, baseRevisionId: string) =>
  createChatTurn(db, ownerId, stickerId, {
    text: "Give it some motion",
    intent: "animate",
    baseRevisionId,
    attachments: [],
    imagePlacement: "replace",
  });

/**
 * A separated part on a transparent 1024 frame, drawn where the reference had it. Each call
 * lands its block in the next cell of a grid, so every part measures somewhere different.
 */
export async function separatedPart(index: number): Promise<Uint8Array> {
  const size = 1024;
  const pixels = Buffer.alloc(size * size * 4);
  const left = 62 + (index % 4) * 250;
  const top = 100 + Math.floor(index / 4) * 300;
  for (let y = top; y < top + 200; y += 1) {
    for (let x = left; x < left + 200; x += 1) {
      const offset = (y * size + x) * 4;
      pixels[offset] = 220;
      pixels[offset + 1] = 70;
      pixels[offset + 2] = 90;
      pixels[offset + 3] = 255;
    }
  }
  return new Uint8Array(await sharp(pixels, { raw: { width: size, height: size, channels: 4 } }).png().toBuffer());
}

/**
 * The turn's attachments, as the agents are given them.
 *
 * Compared by bytes rather than by identity: the point of these tests is that the pixels the user
 * uploaded reach the model, not that some array of the right length was constructed.
 */
export const attachedBytes = (references: Array<{ bytes: Uint8Array }>) =>
  references.map((reference) => [...reference.bytes]);

export async function attachablePhoto(
  db: Awaited<ReturnType<typeof createTestDatabase>>["db"],
  store: MemoryObjectStore,
  ownerId: string,
) {
  const id = crypto.randomUUID();
  const key = objectKey(ownerId, id, "image/png");
  const bytes = new Uint8Array([137, 80, 78, 71]);
  await db.insert(assets).values({
    id, ownerId, kind: "reference", state: "ready", r2Key: key, mimeType: "image/png",
    byteSize: bytes.byteLength, createdAt: new Date(), readyAt: new Date(),
  });
  await store.put(key, { bytes, contentType: "image/png" });
  return { id, bytes: [...bytes] };
}
