import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { StickerDocumentSchema, type StickerDocument } from "@/lib/contracts/sticker";
import { firstRow, type Database } from "@/lib/db/client";
import { chatMessages, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { createCandidateRevision, createSticker, isValidAnimationBase } from "@/lib/services/stickers";
import { createTestDatabase } from "@/tests/helpers/database";

/**
 * What may be animated.
 *
 * Motion used to require the accepted active revision, which meant a user had to decide about the
 * artwork before they were allowed to see it move. The rule is now "a live revision of this
 * sticker", and these cases pin both halves of that: the candidates it deliberately lets through,
 * and the stale or foreign revisions it still has to refuse.
 */
describe("animation base", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await db.insert(users).values({ id: "owner", createdAt: new Date(), updatedAt: new Date() });
  });

  afterEach(async () => { await close(); });

  const emptyAnimated = (): StickerDocument => StickerDocumentSchema.parse({
    version: 1,
    canvas: { width: 1024, height: 1024, coordinateSpace: "normalized", transparent: true },
    kind: "animated",
    durationSeconds: 2,
    fps: 30,
    loop: "loop",
    mp4Background: { type: "solid", color: "#FFFFFF" },
    layers: [],
  });

  /** A sticker plus a chain of candidate revisions, oldest first. */
  async function chainOf(length: number, kind: "animated" | "static" = "animated") {
    const sticker = await createSticker(db, "owner", { title: "Chain", kind, prompt: "Chain", referenceAssetIds: [] });
    const messageId = crypto.randomUUID();
    await db.insert(chatMessages).values({
      id: messageId,
      threadId: sticker.threadId,
      ownerId: "owner",
      role: "user",
      // Deliberately not `animation`: the rule under test used to insist every revision between the
      // base and the kept one came from an animation turn.
      kind: "text",
      content: "Chain",
      sequence: 1,
      status: "complete",
      createdAt: new Date(),
    });
    const document = kind === "animated"
      ? emptyAnimated()
      : StickerDocumentSchema.parse({ ...emptyAnimated(), kind: "static", durationSeconds: 0, fps: 0, loop: "once" });
    const ids: string[] = [];
    for (let index = 0; index < length; index += 1) {
      ids.push(await createCandidateRevision(db, {
        ownerId: "owner",
        stickerId: sticker.stickerId,
        sourceMessageId: messageId,
        document,
        parentRevisionId: ids.at(-1),
      }));
    }
    return { stickerId: sticker.stickerId, ids };
  }

  const load = async (stickerId: string, revisionId: string) => ({
    sticker: (await db.select().from(stickers).where(eq(stickers.id, stickerId)).then(firstRow))!,
    revision: (await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, revisionId)).then(firstRow))!,
  });

  const keep = async (stickerId: string, revisionId: string) => {
    await db.update(stickerRevisions).set({ candidateState: "accepted" }).where(eq(stickerRevisions.id, revisionId));
    await db.update(stickers).set({ activeRevisionId: revisionId }).where(eq(stickers.id, stickerId));
  };

  it("accepts a candidate when nothing has been kept yet", async () => {
    const { stickerId, ids } = await chainOf(1);
    const { sticker, revision } = await load(stickerId, ids[0]);
    expect(sticker.activeRevisionId).toBeNull();
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(true);
  });

  it("accepts a candidate produced by any turn, not just an earlier animation", async () => {
    // The old rule walked to the accepted revision and demanded every hop came from an `animation`
    // chat message, so a candidate from a generate or an edit was refused. These revisions have a
    // plain text source message, which is exactly that case.
    const { stickerId, ids } = await chainOf(3);
    await keep(stickerId, ids[0]);
    const { sticker, revision } = await load(stickerId, ids[2]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(true);
  });

  it("accepts the kept revision itself", async () => {
    const { stickerId, ids } = await chainOf(1);
    await keep(stickerId, ids[0]);
    const { sticker, revision } = await load(stickerId, ids[0]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(true);
  });

  it("refuses a base the user already turned down", async () => {
    const { stickerId, ids } = await chainOf(2);
    await keep(stickerId, ids[0]);
    await db.update(stickerRevisions).set({ candidateState: "rejected" }).where(eq(stickerRevisions.id, ids[1]));
    const { sticker, revision } = await load(stickerId, ids[1]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("refuses a base a later accept swept aside", async () => {
    const { stickerId, ids } = await chainOf(2);
    await keep(stickerId, ids[0]);
    await db.update(stickerRevisions).set({ candidateState: "superseded" }).where(eq(stickerRevisions.id, ids[1]));
    const { sticker, revision } = await load(stickerId, ids[1]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("refuses a live candidate whose ancestry runs through a rejected revision", async () => {
    const { stickerId, ids } = await chainOf(3);
    await keep(stickerId, ids[0]);
    await db.update(stickerRevisions).set({ candidateState: "rejected" }).where(eq(stickerRevisions.id, ids[1]));
    const { sticker, revision } = await load(stickerId, ids[2]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("refuses a candidate on a branch that never reaches the kept revision", async () => {
    const { stickerId, ids } = await chainOf(2);
    const orphan = await chainOf(1);
    await keep(stickerId, ids[0]);
    // A revision of this sticker, live, but parented to nothing that leads back to what was kept.
    const { sticker } = await load(stickerId, ids[0]);
    const { revision } = await load(orphan.stickerId, orphan.ids[0]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("refuses a base belonging to another sticker", async () => {
    const mine = await chainOf(1);
    const theirs = await chainOf(1);
    await keep(mine.stickerId, mine.ids[0]);
    const { sticker } = await load(mine.stickerId, mine.ids[0]);
    const { revision } = await load(theirs.stickerId, theirs.ids[0]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("refuses a static base", async () => {
    const { stickerId, ids } = await chainOf(1, "static");
    const { sticker, revision } = await load(stickerId, ids[0]);
    expect(await isValidAnimationBase(db, sticker, revision)).toBe(false);
  });

  it("cannot be given a cycle to walk, because ancestry is immutable", async () => {
    // The walk's own cycle guard is defence in depth. This is what actually keeps it unreachable,
    // and it is the thing that would break silently if the trigger were ever relaxed.
    const { stickerId, ids } = await chainOf(2);
    await keep(stickerId, ids[0]);
    // Drizzle wraps the driver error, so the trigger's own "core fields are immutable" text is only
    // on the cause; that it rejects at all is the invariant worth pinning.
    await expect(db.update(stickerRevisions).set({ parentRevisionId: ids[1] }).where(eq(stickerRevisions.id, ids[1])))
      .rejects.toThrow();
  });

  it("refuses when there is no base revision at all", async () => {
    const { stickerId, ids } = await chainOf(1);
    const { sticker } = await load(stickerId, ids[0]);
    expect(await isValidAnimationBase(db, sticker, undefined)).toBe(false);
  });
});
