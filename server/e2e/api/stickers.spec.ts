import { expect, test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("sticker creation API persists a generated revision and streams completion", async ({ request }) => {
  test.setTimeout(120_000);
  const auth = await headers(request, `?sub=sticker-owner-${crypto.randomUUID()}`);
  const writeHeaders = { ...auth, "idempotency-key": crypto.randomUUID() };
  const data = { title: "API generated cloud", kind: "static", prompt: "A happy cloud", referenceAssetIds: [] };
  const response = await request.post("/api/v1/stickers", { headers: writeHeaders, data });
  expect(response.status()).toBe(202);
  const created = await response.json();
  expect(created.job.state).toBe("queued");
  const replay = await request.post("/api/v1/stickers", { headers: writeHeaders, data });
  expect(replay.headers()["idempotency-replayed"]).toBe("true");
  expect(await replay.json()).toEqual(created);
  const events = await request.get(created.job.eventsUrl, { headers: auth, timeout: 60_000 });
  expect(events.status()).toBe(200);
  expect(events.headers()["content-type"]).toContain("text/event-stream");
  const stream = await events.text();
  expect(stream).toContain("event: completed");
  expect(stream).toContain('"jobState":"succeeded"');
  const revisions = await request.get(`/api/v1/stickers/${created.stickerId}`, { headers: auth });
  expect(revisions.status()).toBe(200);
  const detail = await revisions.json();
  expect(detail.revisions).toEqual(expect.arrayContaining([
    expect.objectContaining({ id: created.job.id, document: expect.objectContaining({ kind: "static" }) }),
  ]));
  await expectError(await request.get(created.job.eventsUrl, { headers: await headers(request, "?sub=outsider") }), 404, "JOB_NOT_FOUND");
});
