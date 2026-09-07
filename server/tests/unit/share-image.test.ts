import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { shareImage, shareThumbnail } from "@/lib/share-image";

afterEach(() => vi.unstubAllGlobals());

it("decodes artwork and keeps a lone sticker visible above the decorative cards", async () => {
  const source = await sharp({ create: { width: 400, height: 400, channels: 4, background: "#785adc" } })
    .webp().toBuffer();
  const thumbnail = await shareThumbnail(`data:image/webp;base64,${source.toString("base64")}`);
  expect(thumbnail).toMatch(/^data:image\/png;base64,/);
  const decoded = Buffer.from(thumbnail!.split(",")[1], "base64");
  expect(await sharp(decoded).metadata()).toMatchObject({ format: "png", width: 260, height: 260 });

  const response = shareImage({ title: "Purple stickers", subtitle: "by Mika · 1 sticker", pack: true, thumbnails: [thumbnail] });
  const bytes = Buffer.from(await response.arrayBuffer());
  expect(await sharp(bytes).metadata()).toMatchObject({ format: "png", width: 1200, height: 630 });
  const { data, info } = await sharp(bytes).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  let purplePixels = 0;
  for (let index = 0; index < data.length; index += info.channels) {
    if (data[index + 2] > data[index] + 40 && data[index + 2] > data[index + 1] + 40) purplePixels++;
  }
  expect(purplePixels).toBeGreaterThan(20_000);
});

it("uses a fallback for missing, expired, corrupt, or unreachable artwork", async () => {
  expect(await shareThumbnail(null)).toBeNull();
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  fetch.mockResolvedValueOnce(new Response(null, { status: 403 }));
  expect(await shareThumbnail("https://art.example/expired")).toBeNull();
  fetch.mockResolvedValueOnce(new Response("not an image"));
  expect(await shareThumbnail("https://art.example/corrupt")).toBeNull();
  fetch.mockRejectedValueOnce(new DOMException("Timed out", "TimeoutError"));
  expect(await shareThumbnail("https://art.example/slow")).toBeNull();
});

it("cancels oversized downloads before decoding them", async () => {
  const cancel = vi.fn();
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(8 * 1024 * 1024 + 1)); },
    cancel,
  }))));
  expect(await shareThumbnail("https://art.example/large")).toBeNull();
  expect(cancel).toHaveBeenCalledOnce();
});
