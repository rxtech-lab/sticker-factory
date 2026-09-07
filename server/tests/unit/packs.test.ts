import { and, eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { firstRow, type Database } from "@/lib/db/client";
import { packInstalls, stickerPackItems, stickerPacks, stickers } from "@/lib/db/schema";
import {
  MAX_INSTALLED_PACKS,
  addPackItem,
  createPack,
  deletePack,
  ensureCreatorProfile,
  getPack,
  installPack,
  listHiddenPackMembers,
  listInstalledPacks,
  listMarketplacePacks,
  listOwnPacks,
  listPacksByCreator,
  publishPack,
  recomputePackCounters,
  removePackItem,
  reorderPackItems,
  uninstallPack,
  unpublishPack,
  updatePack,
} from "@/lib/services/packs";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

describe("sticker packs", () => {
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

  const counters = async (packId: string) =>
    db.select({
      installCount: stickerPacks.installCount,
      installTotal: stickerPacks.installTotal,
      itemCount: stickerPacks.itemCount,
    }).from(stickerPacks).where(eq(stickerPacks.id, packId)).then(firstRow);

  it("runs the create -> publish -> install -> uninstall lifecycle", async () => {
    const a = await seedPublishedSticker(db, "creator", { title: "Wave" });
    const b = await seedPublishedSticker(db, "creator", { title: "Grin" });

    const pack = await createPack(db, "creator", { title: "Cozy Cats", stickerIds: [a.stickerId, b.stickerId] });
    expect(pack.state).toBe("draft");
    expect(pack.itemCount).toBe(2);
    expect(pack.stickers.map((sticker) => sticker.title)).toEqual(["Wave", "Grin"]);
    expect(pack.isMine).toBe(true);
    expect(pack.installed).toBe(false);

    // A draft pack is invisible to everybody but its creator.
    await expect(getPack(db, "installer", pack.id)).rejects.toMatchObject({ code: "PACK_NOT_FOUND" });
    expect((await listMarketplacePacks(db, "installer", {})).data).toHaveLength(0);

    const published = await publishPack(db, "creator", pack.id);
    expect(published.state).toBe("published");
    expect(published.publishedAt).not.toBeNull();
    expect((await listMarketplacePacks(db, "installer", {})).data.map((row) => row.id)).toEqual([pack.id]);

    await installPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 1, installTotal: 1 });
    expect((await getPack(db, "installer", pack.id)).installed).toBe(true);
    expect((await listInstalledPacks(db, "installer")).map((row) => row.id)).toEqual([pack.id]);

    await uninstallPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 0, installTotal: 1 });
    expect(await listInstalledPacks(db, "installer")).toHaveLength(0);
  });

  it("keeps install counters exact across duplicates, reinstalls, and a recompute", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Counting", stickerIds: [sticker.stickerId], state: "published" });

    await installPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 1, installTotal: 1 });

    // A repeated install is a no-op, not a second row and not a second increment.
    await installPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 1, installTotal: 1 });

    await uninstallPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 0 });
    // Uninstall flips state; it must not delete the row, or the entitlement is lost.
    expect(await db.select().from(packInstalls).where(eq(packInstalls.packId, pack.id))).toHaveLength(1);

    await uninstallPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 0 });

    await installPack(db, "installer", pack.id);
    expect(await counters(pack.id)).toMatchObject({ installCount: 1, installTotal: 2 });

    // Deliberately corrupt the denormalized counters, then prove the reconciler restores them.
    await db.update(stickerPacks).set({ installCount: 97, itemCount: 42 }).where(eq(stickerPacks.id, pack.id));
    await recomputePackCounters(db);
    expect(await counters(pack.id)).toMatchObject({ installCount: 1, itemCount: 1, installTotal: 2 });
  });

  it.each([-3, 42])("counts visible members across pack surfaces despite a stored count of %i", async (itemCount) => {
    const stickerIds: string[] = [];
    for (let index = 0; index < 7; index += 1) {
      stickerIds.push((await seedPublishedSticker(db, "creator")).stickerId);
    }
    const pack = await createPack(db, "creator", {
      title: "Count actual stickers", stickerIds, state: "published",
    });
    await installPack(db, "installer", pack.id);
    await db.update(stickers).set({ status: "draft", activeRevisionId: null })
      .where(eq(stickers.id, stickerIds[6]));
    await db.update(stickerPacks).set({ itemCount }).where(eq(stickerPacks.id, pack.id));

    const detail = await getPack(db, "installer", pack.id);
    expect(detail.stickers).toHaveLength(6);
    expect(detail.itemCount).toBe(6);
    const profile = await ensureCreatorProfile(db, "creator");
    const pages = [
      (await listMarketplacePacks(db, "installer")).data,
      (await listOwnPacks(db, "creator")).data,
      (await listPacksByCreator(db, "installer", profile.handle)).data,
      await listInstalledPacks(db, "installer"),
    ];
    for (const page of pages) {
      expect(page).toHaveLength(1);
      expect(page[0].itemCount).toBe(6);
      expect(page[0].coverStickers).toHaveLength(4);
    }
  });

  it("refuses stickers the creator does not own or has not published", async () => {
    const own = await seedPublishedSticker(db, "creator");
    const foreign = await seedPublishedSticker(db, "installer");
    const draft = await seedPublishedSticker(db, "creator");
    await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, draft.stickerId));

    await expect(createPack(db, "creator", { title: "Nope", stickerIds: [foreign.stickerId] }))
      .rejects.toMatchObject({ code: "PACK_STICKER_NOT_OWNED" });
    await expect(createPack(db, "creator", { title: "Nope", stickerIds: [draft.stickerId] }))
      .rejects.toMatchObject({ code: "PACK_STICKER_NOT_PUBLISHED" });

    const pack = await createPack(db, "creator", { title: "Fine", stickerIds: [own.stickerId] });
    await expect(addPackItem(db, "creator", pack.id, foreign.stickerId))
      .rejects.toMatchObject({ code: "PACK_STICKER_NOT_OWNED" });

    // The service check is the friendly error; the database trigger is the backstop underneath it.
    await expect(db.insert(stickerPackItems).values({
      packId: pack.id,
      stickerId: foreign.stickerId,
      position: 9,
      addedAt: new Date(),
    })).rejects.toMatchObject({ cause: { message: expect.stringMatching(/owned by its creator/) } });
  });

  it("refuses to publish a pack with nothing visible in it", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const empty = await createPack(db, "creator", { title: "Empty" });
    await expect(publishPack(db, "creator", empty.id)).rejects.toMatchObject({ code: "PACK_EMPTY" });
    await expect(createPack(db, "creator", { title: "Empty", state: "published" }))
      .rejects.toMatchObject({ code: "PACK_EMPTY" });

    // A pack whose only member fell back to draft is just as unpublishable.
    const hollow = await createPack(db, "creator", { title: "Hollow", stickerIds: [sticker.stickerId] });
    await db.update(stickers).set({ status: "draft" }).where(eq(stickers.id, sticker.stickerId));
    await expect(publishPack(db, "creator", hollow.id)).rejects.toMatchObject({ code: "PACK_EMPTY" });
  });

  it("rejects self-install and enforces the installed-pack cap", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Mine", stickerIds: [sticker.stickerId], state: "published" });
    await expect(installPack(db, "creator", pack.id)).rejects.toMatchObject({ code: "PACK_SELF_INSTALL" });
    expect(await counters(pack.id)).toMatchObject({ installCount: 0 });

    for (let index = 0; index < MAX_INSTALLED_PACKS; index += 1) {
      const member = await seedPublishedSticker(db, "creator");
      const filler = await createPack(db, "creator", { title: `Filler ${index}`, stickerIds: [member.stickerId], state: "published" });
      await installPack(db, "installer", filler.id);
    }
    await expect(installPack(db, "installer", pack.id)).rejects.toMatchObject({ code: "TOO_MANY_INSTALLED_PACKS" });
  });

  it("keeps the slug stable across a rename and resolves a pack by either key", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Vibe Check", stickerIds: [sticker.stickerId], state: "published" });
    expect(pack.slug).toMatch(/^vibe-check-[0-9a-f]{8}$/);

    const renamed = await updatePack(db, "creator", pack.id, { title: "Totally Different", summary: "Now with feeling" });
    expect(renamed.slug).toBe(pack.slug);
    expect(renamed.title).toBe("Totally Different");
    expect(renamed.summary).toBe("Now with feeling");

    // A link someone already shared has to keep working after the rename.
    expect((await getPack(db, "installer", pack.slug)).id).toBe(pack.id);
    expect((await getPack(db, "installer", pack.id)).slug).toBe(pack.slug);
  });

  it("mints a stable handle from the display name and never from the email", async () => {
    const first = await ensureCreatorProfile(db, "creator");
    const second = await ensureCreatorProfile(db, "creator");
    expect(first.handle).toBe(second.handle);
    expect(first.handle).toMatch(/^mika-lin-[0-9a-f]{6}$/);

    await seedUser(db, "anon");
    const anonymous = await ensureCreatorProfile(db, "anon");
    expect(anonymous.handle).toMatch(/^creator-[0-9a-f]{6}$/);

    const sticker = await seedPublishedSticker(db, "creator");
    await createPack(db, "creator", { title: "Byline", stickerIds: [sticker.stickerId], state: "published" });
    const page = await listPacksByCreator(db, "installer", first.handle);
    expect(page.creator).toMatchObject({ handle: first.handle, displayName: "Mika Lin", isSelf: false, packCount: 1 });
    expect(page.data).toHaveLength(1);
    expect((await listPacksByCreator(db, "creator", first.handle)).creator.isSelf).toBe(true);
  });

  it("reorders, re-covers, and tombstones rather than deleting", async () => {
    const a = await seedPublishedSticker(db, "creator", { title: "A" });
    const b = await seedPublishedSticker(db, "creator", { title: "B" });
    const c = await seedPublishedSticker(db, "creator", { title: "C" });
    const pack = await createPack(db, "creator", { title: "Order", stickerIds: [a.stickerId, b.stickerId], state: "published" });

    const reordered = await reorderPackItems(db, "creator", pack.id, [c.stickerId, a.stickerId, b.stickerId]);
    expect(reordered.stickers.map((sticker) => sticker.title)).toEqual(["C", "A", "B"]);
    expect(reordered.itemCount).toBe(3);

    // Removing the cover has to promote the next member, not leave a dangling reference.
    const withoutCover = await removePackItem(db, "creator", pack.id, c.stickerId);
    expect(withoutCover.stickers.map((sticker) => sticker.title)).toEqual(["A", "B"]);
    const row = await db.select().from(stickerPacks).where(eq(stickerPacks.id, pack.id)).then(firstRow);
    expect(row?.coverStickerId).toBe(a.stickerId);

    await installPack(db, "installer", pack.id);
    await deletePack(db, "creator", pack.id);
    // The row survives so a future purchase record survives with it, but nothing can reach it.
    expect((await db.select().from(stickerPacks).where(eq(stickerPacks.id, pack.id)).then(firstRow))?.state).toBe("removed");
    await expect(getPack(db, "installer", pack.id)).rejects.toMatchObject({ code: "PACK_NOT_FOUND" });
    await expect(getPack(db, "creator", pack.id)).rejects.toMatchObject({ code: "PACK_NOT_FOUND" });
    expect(await listInstalledPacks(db, "installer")).toHaveLength(0);
    expect(await counters(pack.id)).toMatchObject({ installCount: 0 });
  });

  it("hides an unpublished pack from installers but keeps it for its creator", async () => {
    const sticker = await seedPublishedSticker(db, "creator");
    const pack = await createPack(db, "creator", { title: "Retract", stickerIds: [sticker.stickerId], state: "published" });
    await installPack(db, "installer", pack.id);

    await unpublishPack(db, "creator", pack.id, "draft");
    await expect(getPack(db, "installer", pack.id)).rejects.toMatchObject({ code: "PACK_NOT_FOUND" });
    expect(await listInstalledPacks(db, "installer")).toHaveLength(0);
    expect((await getPack(db, "creator", pack.id)).state).toBe("draft");
    expect((await listOwnPacks(db, "creator")).data.map((row) => row.id)).toEqual([pack.id]);

    // `unlisted` stays reachable by direct link and keeps installers whole; it just leaves browse.
    await unpublishPack(db, "creator", pack.id, "unlisted");
    expect((await getPack(db, "installer", pack.slug)).state).toBe("unlisted");
    expect(await listInstalledPacks(db, "installer")).toHaveLength(1);
    expect((await listMarketplacePacks(db, "installer", {})).data).toHaveLength(0);
  });

  it("tells the creator which members installers cannot see", async () => {
    const visible = await seedPublishedSticker(db, "creator", { title: "Visible" });
    const demoted = await seedPublishedSticker(db, "creator", { title: "Demoted" });
    const pack = await createPack(db, "creator", {
      title: "Mixed",
      stickerIds: [visible.stickerId, demoted.stickerId],
      state: "published",
    });

    // Exactly what a device edit does: the sticker drops back to draft and silently leaves.
    await db.update(stickers).set({ status: "draft", activeRevisionId: null }).where(eq(stickers.id, demoted.stickerId));

    expect((await getPack(db, "installer", pack.id)).stickers.map((sticker) => sticker.title)).toEqual(["Visible"]);
    expect(await listHiddenPackMembers(db, "creator", pack.id)).toEqual([
      { id: demoted.stickerId, title: "Demoted", status: "draft" },
    ]);
  });

  it("paginates browse by recency and by popularity", async () => {
    const packIds: string[] = [];
    for (let index = 0; index < 3; index += 1) {
      const sticker = await seedPublishedSticker(db, "creator");
      const pack = await createPack(db, "creator", { title: `Pack ${index}`, stickerIds: [sticker.stickerId], state: "published" });
      packIds.push(pack.id);
      await db.update(stickerPacks)
        .set({ publishedAt: new Date(1_700_000_000_000 + index * 1000) })
        .where(eq(stickerPacks.id, pack.id));
    }
    // Give the middle pack the most installs so the two sorts disagree.
    await seedUser(db, "fan-1");
    await seedUser(db, "fan-2");
    await installPack(db, "fan-1", packIds[1]);
    await installPack(db, "fan-2", packIds[1]);
    await installPack(db, "installer", packIds[0]);

    const recent = await listMarketplacePacks(db, "installer", { sort: "recent" });
    expect(recent.data.map((row) => row.id)).toEqual([packIds[2], packIds[1], packIds[0]]);

    const popular = await listMarketplacePacks(db, "installer", { sort: "popular" });
    expect(popular.data.map((row) => row.id)).toEqual([packIds[1], packIds[0], packIds[2]]);
    expect(popular.data[0].installCount).toBe(2);
    // `installed` is per-viewer, not a property of the pack.
    expect(popular.data.find((row) => row.id === packIds[0])?.installed).toBe(true);
    expect(popular.data.find((row) => row.id === packIds[1])?.installed).toBe(false);

    const firstPage = await listMarketplacePacks(db, "installer", { sort: "recent", limit: 2 });
    expect(firstPage.data.map((row) => row.id)).toEqual([packIds[2], packIds[1]]);
    expect(firstPage.nextCursor).not.toBeNull();
    const secondPage = await listMarketplacePacks(db, "installer", { sort: "recent", limit: 2, cursor: firstPage.nextCursor });
    expect(secondPage.data.map((row) => row.id)).toEqual([packIds[0]]);
    expect(secondPage.nextCursor).toBeNull();

    // Popularity pages on an integer key rather than a timestamp, so it needs its own check.
    const popularFirst = await listMarketplacePacks(db, "installer", { sort: "popular", limit: 2 });
    expect(popularFirst.data.map((row) => row.id)).toEqual([packIds[1], packIds[0]]);
    const popularSecond = await listMarketplacePacks(db, "installer", { sort: "popular", limit: 2, cursor: popularFirst.nextCursor });
    expect(popularSecond.data.map((row) => row.id)).toEqual([packIds[2]]);
    expect(popularSecond.nextCursor).toBeNull();

    await expect(listMarketplacePacks(db, "installer", { cursor: "not-base64-json" }))
      .rejects.toMatchObject({ code: "INVALID_CURSOR" });
  });

  it("filters browse by title", async () => {
    for (const title of ["Cozy Cats", "Angry Dogs"]) {
      const sticker = await seedPublishedSticker(db, "creator");
      await createPack(db, "creator", { title, stickerIds: [sticker.stickerId], state: "published" });
    }
    const hits = await listMarketplacePacks(db, "installer", { query: "cats" });
    expect(hits.data.map((row) => row.title)).toEqual(["Cozy Cats"]);

    // A wildcard typed into a search field is a character, not a pattern.
    expect((await listMarketplacePacks(db, "installer", { query: "%" })).data).toHaveLength(0);
  });

  it("filters the authoring list by title, drafts included", async () => {
    for (const title of ["Cozy Cats", "Angry Dogs"]) {
      const sticker = await seedPublishedSticker(db, "creator");
      await createPack(db, "creator", { title, stickerIds: [sticker.stickerId], state: "published" });
    }
    const draftSticker = await seedPublishedSticker(db, "creator");
    await createPack(db, "creator", { title: "Draft Cats", stickerIds: [draftSticker.stickerId] });

    const hits = await listOwnPacks(db, "creator", { query: "cats" });
    expect(hits.data.map((row) => row.title).sort()).toEqual(["Cozy Cats", "Draft Cats"]);
    expect((await listOwnPacks(db, "creator", { query: "nothing here" })).data).toHaveLength(0);
    // An empty query is not a filter: it is the unsearched list.
    expect((await listOwnPacks(db, "creator", { query: "   " })).data).toHaveLength(3);
  });

  it("drops a hard-deleted member from every pack that held it", async () => {
    const keep = await seedPublishedSticker(db, "creator", { title: "Keep" });
    const doomed = await seedPublishedSticker(db, "creator", { title: "Doomed" });
    const pack = await createPack(db, "creator", {
      title: "Attrition",
      stickerIds: [keep.stickerId, doomed.stickerId],
      state: "published",
    });
    expect((await counters(pack.id))?.itemCount).toBe(2);

    await db.delete(stickers).where(eq(stickers.id, doomed.stickerId));
    expect(await db.select().from(stickerPackItems)
      .where(and(eq(stickerPackItems.packId, pack.id), eq(stickerPackItems.stickerId, doomed.stickerId)))).toHaveLength(0);
    expect((await getPack(db, "creator", pack.id)).stickers.map((sticker) => sticker.title)).toEqual(["Keep"]);
  });
});
