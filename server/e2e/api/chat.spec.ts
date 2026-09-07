import { expect, test } from "@playwright/test";
import { headers, expectError } from "../support/api";

test("chat API completes a durable workflow using the AI SDK mock tool call", async ({ request }) => {
  test.setTimeout(180_000);
  const auth = await headers(request, `?sub=chat-owner-${crypto.randomUUID()}`);
  const created = await request.post("/api/v1/stickers", {
    headers: { ...auth, "idempotency-key": crypto.randomUUID() },
    data: { title: "Chat fixture", kind: "static", prompt: "A cloud", referenceAssetIds: [] },
  });
  expect(created.status()).toBe(202);
  const sticker = await created.json();
  const generation = await request.get(sticker.job.eventsUrl, { headers: auth, timeout: 60_000 });
  expect(await generation.text()).toContain('"jobState":"succeeded"');
  const staticStickerId = sticker.stickerId;
  const path = `/api/v1/stickers/${staticStickerId}/chat/messages`;
  const writeHeaders = { ...auth, "idempotency-key": crypto.randomUUID() };
  const data = { text: "What can you tell me about my sticker?", intent: "chat" };
  const submitted = await request.post(path, { headers: writeHeaders, data });
  expect(submitted.status()).toBe(202);
  const turn = await submitted.json();
  expect(turn.job.state).toBe("queued");
  expect(turn.job.workflowRunId).toBeTruthy();
  const replay = await request.post(path, { headers: writeHeaders, data });
  expect(replay.headers()["idempotency-replayed"]).toBe("true");
  expect(await replay.json()).toEqual(turn);
  await expect.poll(async () => {
    const response = await request.get(path, { headers: auth });
    expect(response.status()).toBe(200);
    const messages = (await response.json()).data as Array<{ jobId: string; role: string; status: string; content: string }>;
    const reply = messages.find((message) => message.jobId === turn.job.id && message.role === "assistant" && message.status === "complete");
    return reply?.content ?? "";
  }, { timeout: 90_000 }).toContain("AI SDK mock reply: your sticker is ready to discuss.");
  await expectError(await request.get(path, { headers: await headers(request, "?sub=outsider") }), 404, "STICKER_NOT_FOUND");
});
