import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Database } from "@/lib/db/client";
import { stickers } from "@/lib/db/schema";
import { formatTimings, runTimed } from "@/lib/http/timing";
import { MAX_PACK_ITEMS, createPack, installPack, listLibrarySections, uninstallPack } from "@/lib/services/packs";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("library sections", () => {
  let db: Database;
  let close: () => Promise<void>;

  beforeEach(async () => {
    ({ db, close } = await createTestDatabase());
    await seedUser(db, "creator", "Mika Lin");
    await seedUser(db, "installer", "Sam");
  });

  afterEach(async () => {
    await close();
  });

  it("puts the user's own stickers first, then one section per installed pack", async () => {
    const own = await seedPublishedSticker(db, "installer", { title: "My Own" });
    const theirs = await seedPublishedSticker(db, "creator", { title: "Borrowed" });
    const pack = await createPack(db, "creator", { title: "Cozy Cats", stickerIds: [theirs.stickerId], state: "published" });
    await installPack(db, "installer", pack.id);

    const { sections } = await listLibrarySections(db, "installer");
    expect(sections.map((section) => section.id)).toEqual(["mine", `pack:${pack.id}`]);

    const [mine, borrowed] = sections;
    expect(mine).toMatchObject({ kind: "mine", title: "My Stickers", packId: null, creator: null });
    expect(mine.stickers.map((sticker) => sticker.id)).toEqual([own.stickerId]);

    expect(borrowed).toMatchObject({ kind: "pack", title: "Cozy Cats", packId: pack.id, packSlug: pack.slug });
    expect(borrowed.creator).toMatchObject({ displayName: "Mika Lin", isSelf: false });
    expect(borrowed.installedAt).not.toBeNull();
    expect(borrowed.stickers.map((sticker) => sticker.title)).toEqual(["Borrowed"]);
    // The system rendition is what both the Library card and the Messages grid render.
    expect(borrowed.stickers[0].systemSticker?.assetId).toBe(theirs.systemAssetId);
  });

  it("loads the three section result sets in one database batch", async () => {
    await seedPublishedSticker(db, "installer", { title: "My Own" });
    const theirs = await seedPublishedSticker(db, "creator", { title: "Borrowed" });
    const pack = await createPack(db, "creator", {
      title: "Cozy Cats",
      stickerIds: [theirs.stickerId],
      state: "published",
    });
    await installPack(db, "installer", pack.id);

    const timings = await runTimed(async () => {
      await listLibrarySections(db, "installer");
      return formatTimings();
    });

    expect(timings).toMatch(/^db=/);
    expect(timings).not.toContain("db x");
  });

  /**
   * The two extra sizes have to survive both halves of this response, and they are resolved by
   * different queries: `selectStickerSummaries` for the user's own stickers and `loadPackMembers`
   * for an installed pack's. A join missing from either one reads to the extension as "this sticker
   * only has Large", which is indistinguishable from a sticker published before they existed.
   */
  it("carries the attachment renditions through both the own and the pack query", async () => {
    const own = await seedPublishedSticker(db, "installer", { title: "My Own", attachments: true });
    const theirs = await seedPublishedSticker(db, "creator", { title: "Borrowed", attachments: true });
    const legacy = await seedPublishedSticker(db, "creator", { title: "Legacy" });
    const pack = await createPack(db, "creator", {
      title: "Cozy Cats",
      stickerIds: [theirs.stickerId, legacy.stickerId],
      state: "published",
    });
    await installPack(db, "installer", pack.id);

    const { sections } = await listLibrarySections(db, "installer");
    const [mine, borrowed] = sections;

    expect(mine.stickers[0].attachmentMedium).toMatchObject({ id: own.attachmentMediumAssetId, width: 408 });
    expect(mine.stickers[0].attachmentSmall).toMatchObject({ id: own.attachmentSmallAssetId, width: 300 });

    const byTitle = new Map(borrowed.stickers.map((sticker) => [sticker.title, sticker]));
    expect(byTitle.get("Borrowed")?.attachmentMedium).toMatchObject({ id: theirs.attachmentMediumAssetId, width: 408 });
    expect(byTitle.get("Borrowed")?.attachmentSmall).toMatchObject({ id: theirs.attachmentSmallAssetId, width: 300 });
    // Published before attachment renditions existed. It still lists, and the extension walks up to
    // the size it does have rather than refusing to send.
    expect(byTitle.get("Legacy")?.attachmentMedium).toBeNull();
    expect(byTitle.get("Legacy")?.attachmentSmall).toBeNull();
  });

  it("drops a member the moment it stops being publishable, without dropping its section", async () => {
    const kept = await seedPublishedSticker(db, "creator", { title: "Kept" });
    const demoted = await seedPublishedSticker(db, "creator", { title: "Demoted" });
    const deleting = await seedPublishedSticker(db, "creator", { title: "Deleting" });
    const pack = await createPack(db, "creator", {
      title: "Attrition",
      stickerIds: [kept.stickerId, demoted.stickerId, deleting.stickerId],
      state: "published",
    });
    await installPack(db, "installer", pack.id);

    // A device edit clears the active revision and drops the sticker back to draft.
    await db.update(stickers).set({ status: "draft", activeRevisionId: null }).where(eq(stickers.id, demoted.stickerId));
    // Deletion tombstones the row long before the bytes are purged.
    await db.update(stickers).set({ status: "deleting", deletedAt: new Date() }).where(eq(stickers.id, deleting.stickerId));

    const { sections } = await listLibrarySections(db, "installer");
    expect(sections[1].stickers.map((sticker) => sticker.title)).toEqual(["Kept"]);

    // Hollow the pack out entirely: the section must survive as an empty one, so the installer
    // sees "this pack has nothing right now" rather than a pack that silently vanished.
    await db.update(stickers).set({ status: "draft", activeRevisionId: null }).where(eq(stickers.id, kept.stickerId));
    const hollow = await listLibrarySections(db, "installer");
    expect(hollow.sections.map((section) => section.id)).toEqual(["mine", `pack:${pack.id}`]);
    expect(hollow.sections[1].stickers).toEqual([]);
  });

  it("honours the status filter for the user's own section only", async () => {
    const published = await seedPublishedSticker(db, "installer", { title: "Published" });
    const draft = await seedPublishedSticker(db, "installer", { title: "Draft" });
    await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, draft.stickerId));

    const forMessages = await listLibrarySections(db, "installer", { status: "published" });
    expect(forMessages.sections[0].stickers.map((sticker) => sticker.id)).toEqual([published.stickerId]);

    // The app's Library tab wants drafts too — they are projects in progress, not junk.
    const forApp = await listLibrarySections(db, "installer", { status: "all" });
    expect(forApp.sections[0].stickers.map((sticker) => sticker.title).sort()).toEqual(["Draft", "Published"]);
  });

  it("searches owned and installed stickers by title on the backend", async () => {
    await seedPublishedSticker(db, "installer", { title: "Blue Cloud" });
    await seedPublishedSticker(db, "installer", { title: "Red Rocket" });
    const matching = await seedPublishedSticker(db, "creator", { title: "Cloud Cat" });
    const other = await seedPublishedSticker(db, "creator", { title: "Sleepy Loaf" });
    const cloudPack = await createPack(db, "creator", {
      title: "Weather Cats",
      stickerIds: [matching.stickerId, other.stickerId],
      state: "published",
    });
    const unrelatedPack = await createPack(db, "creator", {
      title: "Bread Cats",
      stickerIds: [other.stickerId],
      state: "published",
    });
    await installPack(db, "installer", cloudPack.id);
    await installPack(db, "installer", unrelatedPack.id);

    const { sections } = await listLibrarySections(db, "installer", { status: "all", query: "  cloud  " });

    expect(sections.map((section) => section.title)).toEqual(["My Stickers", "Weather Cats"]);
    expect(sections[0].stickers.map((sticker) => sticker.title)).toEqual(["Blue Cloud"]);
    expect(sections[1].stickers.map((sticker) => sticker.title)).toEqual(["Cloud Cat"]);

    const literalWildcard = await listLibrarySections(db, "installer", { status: "all", query: "%" });
    expect(literalWildcard.sections).toHaveLength(1);
    expect(literalWildcard.sections[0].stickers).toEqual([]);
  });

  it("removes a section on uninstall and caps a section's size", async () => {
    const member = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Temporary", stickerIds: [member.stickerId], state: "published" });
    await installPack(db, "installer", pack.id);
    expect((await listLibrarySections(db, "installer")).sections).toHaveLength(2);

    await uninstallPack(db, "installer", pack.id);
    const after = await listLibrarySections(db, "installer");
    expect(after.sections.map((section) => section.id)).toEqual(["mine"]);
    expect(after.generatedAt).toMatch(/^\d{4}-/);
  });

  it("bounds a pack section at the item cap", async () => {
    const stickerIds: string[] = [];
    for (let index = 0; index < MAX_PACK_ITEMS; index += 1) {
      stickerIds.push((await seedPublishedSticker(db, "creator", { title: `S${index}` })).stickerId);
    }
    const pack = await createPack(db, "creator", { title: "Full", stickerIds, state: "published" });
    await installPack(db, "installer", pack.id);
    const { sections } = await listLibrarySections(db, "installer");
    expect(sections[1].stickers).toHaveLength(MAX_PACK_ITEMS);
  });

  it("keeps the same sticker whole in two different installed packs", async () => {
    const shared = await seedPublishedSticker(db, "creator", { title: "Shared" });
    const first = await createPack(db, "creator", { title: "First", stickerIds: [shared.stickerId], state: "published" });
    const second = await createPack(db, "creator", { title: "Second", stickerIds: [shared.stickerId], state: "published" });
    await installPack(db, "installer", first.id);
    await installPack(db, "installer", second.id);

    const { sections } = await listLibrarySections(db, "installer");
    expect(sections.map((section) => section.title)).toEqual(["My Stickers", "First", "Second"]);
    // Both sections carry the same sticker and the same asset id — the extension's cache has to
    // hold two entries pointing at one file.
    expect(sections[1].stickers[0].id).toBe(shared.stickerId);
    expect(sections[2].stickers[0].id).toBe(shared.stickerId);
    expect(sections[1].stickers[0].systemSticker?.assetId).toBe(sections[2].stickers[0].systemSticker?.assetId);
  });
});
