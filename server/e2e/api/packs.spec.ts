import { expect, test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("pack API persists CRUD, isolates owners, and replays idempotent writes", async ({ request }) => {
  const auth = await headers(request, `?sub=pack-owner-${crypto.randomUUID()}`);
  const writeHeaders = { ...auth, "idempotency-key": crypto.randomUUID() };
  const data = { title: "API draft pack", summary: "Created over HTTP" };
  const created = await request.post("/api/v1/packs", { headers: writeHeaders, data });
  expect(created.status()).toBe(201);
  expect(created.headers()["idempotency-replayed"]).toBe("false");
  const pack = await created.json();
  expect(pack.itemCount).toBe(0);
  expect(pack.stickers).toEqual([]);
  const replay = await request.post("/api/v1/packs", { headers: writeHeaders, data });
  expect(replay.status()).toBe(201);
  expect(replay.headers()["idempotency-replayed"]).toBe("true");
  expect(await replay.json()).toEqual(pack);
  await expectError(await request.post("/api/v1/packs", { headers: writeHeaders, data: { title: "Changed" } }), 409, "IDEMPOTENCY_KEY_REUSED");
  const own = await request.get("/api/v1/packs?mine=true", { headers: auth });
  expect((await own.json()).data.map((item: { id: string }) => item.id)).toEqual([pack.id]);
  const outsider = await headers(request, "?sub=outsider");
  await expectError(await request.get(`/api/v1/packs/${pack.id}`, { headers: outsider }), 404, "PACK_NOT_FOUND");
  await expectError(await request.patch(`/api/v1/packs/${pack.id}`, { headers: { ...outsider, "idempotency-key": crypto.randomUUID() }, data: { title: "Stolen" } }), 404, "PACK_NOT_FOUND");
  const updated = await request.patch(`/api/v1/packs/${pack.id}`, { headers: { ...auth, "idempotency-key": crypto.randomUUID() }, data: { title: "Renamed through API" } });
  expect(updated.status()).toBe(200);
  const detail = await request.get(`/api/v1/packs/${pack.id}`, { headers: auth });
  expect((await detail.json()).title).toBe("Renamed through API");
  const deleted = await request.delete(`/api/v1/packs/${pack.id}`, { headers: { ...auth, "idempotency-key": crypto.randomUUID() } });
  expect(deleted.status()).toBe(200);
  await expectError(await request.get(`/api/v1/packs/${pack.id}`, { headers: auth }), 404, "PACK_NOT_FOUND");
});

test("pack itemCount stays consistent across membership writes, detail, and lists", async ({ request }) => {
  test.setTimeout(180_000);
  const seed = await request.post("/api/e2e/seed", {
    headers: { "x-e2e-key": "local-playwright-seed" },
    timeout: 120_000,
  });
  expect(seed.status()).toBe(200);
  const { staticStickerId } = await seed.json();
  const auth = await headers(request);
  const viewer = await headers(request, `?sub=count-viewer-${crypto.randomUUID()}`);
  const writeHeaders = () => ({ ...auth, "idempotency-key": crypto.randomUUID() });
  const title = `API count ${crypto.randomUUID()}`;
  const created = await request.post("/api/v1/packs", {
    headers: writeHeaders(),
    data: { title, stickerIds: [staticStickerId] },
  });
  expect(created.status()).toBe(201);
  const pack = await created.json();
  expect(pack.itemCount).toBe(1);
  expect(pack.stickers.map((sticker: { id: string }) => sticker.id)).toEqual([staticStickerId]);
  const path = `/api/v1/packs/${pack.id}`;
  let published = false;

  async function expectCount(count: number) {
    const detail = await request.get(path, { headers: published ? viewer : auth });
    expect(detail.status()).toBe(200);
    const body = await detail.json();
    expect(body.itemCount).toBe(count);
    expect(body.stickers.map((sticker: { id: string }) => sticker.id))
      .toEqual(count === 0 ? [] : [staticStickerId]);
    const lists = [{ url: `/api/v1/packs?mine=true&q=${encodeURIComponent(title)}`, auth }];
    if (published) lists.push({ url: `/api/v1/packs?q=${encodeURIComponent(title)}`, auth: viewer });
    for (const list of lists) {
      const response = await request.get(list.url, { headers: list.auth });
      expect(response.status()).toBe(200);
      expect((await response.json()).data).toEqual([
        expect.objectContaining({ id: pack.id, itemCount: count }),
      ]);
    }
  }

  try {
    await expectCount(1);
    const publication = await request.post(`${path}/publish`, { headers: writeHeaders() });
    expect(publication.status()).toBe(200);
    expect((await publication.json()).itemCount).toBe(1);
    published = true;
    await expectCount(1);

    const removalHeaders = writeHeaders();
    for (let attempt = 0; attempt < 2; attempt++) {
      const removed = await request.delete(`${path}/items/${staticStickerId}`, { headers: removalHeaders });
      expect(removed.status()).toBe(200);
      expect(removed.headers()["idempotency-replayed"]).toBe(String(attempt === 1));
      expect((await removed.json()).itemCount).toBe(0);
      await expectCount(0);
    }

    const additionHeaders = writeHeaders();
    // Same-key replay and a fresh-key duplicate must both leave exactly one member.
    for (const [index, mutationHeaders] of [additionHeaders, additionHeaders, writeHeaders()].entries()) {
      const added = await request.post(`${path}/items`, {
        headers: mutationHeaders, data: { stickerId: staticStickerId },
      });
      expect(added.status()).toBe(200);
      expect(added.headers()["idempotency-replayed"]).toBe(String(index === 1));
      expect((await added.json()).itemCount).toBe(1);
      await expectCount(1);
    }

    for (const stickerIds of [[], [staticStickerId]]) {
      const replaced = await request.put(`${path}/items`, {
        headers: writeHeaders(), data: { stickerIds },
      });
      expect(replaced.status()).toBe(200);
      expect((await replaced.json()).itemCount).toBe(stickerIds.length);
      await expectCount(stickerIds.length);
    }
  } finally {
    const deleted = await request.delete(path, { headers: writeHeaders() });
    expect(deleted.status()).toBe(200);
  }
});
