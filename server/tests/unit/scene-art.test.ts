import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import sharp from "sharp";
import { authorSVG } from "@/lib/ai/gateway-svg";
import { SVGSceneSchema } from "@/lib/contracts/controllable";
import { generateSceneArt, sceneDesignCheckpoint } from "@/lib/pets/scene-art";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { renderSVG } from "@/lib/controllable/sample";

vi.mock("@/lib/ai/gateway-svg", () => ({ authorSVG: vi.fn() }));
const scene = SVGSceneSchema.parse(JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-scene.json", import.meta.url), "utf8")));
afterEach(() => { setObjectStoreForTests(undefined); vi.resetAllMocks(); });

describe("image then SVG scenes", () => {
  it("retries a failed conversion using the saved image, then reuses the completed SVG", async () => {
    const store = new MemoryObjectStore(); setObjectStoreForTests(store);
    const reference = await sharp({ create: { width: 200, height: 200, channels: 4, background: "#FFD080" } }).png().toBuffer();
    const draw = vi.fn(async () => ({ bytes: reference, mimeType: "image/png" as const }));
    const input = { userId: "owner", kind: "rooms" as const, brief: "A cozy home", style: null, draw };
    vi.mocked(authorSVG).mockRejectedValueOnce(new Error("Conversion failed"));
    await expect(generateSceneArt(input)).rejects.toThrow("Conversion failed");
    expect(store.objects.size).toBe(1);
    vi.mocked(authorSVG).mockResolvedValueOnce(scene);
    const result = await generateSceneArt(input);
    expect(result.scene).toEqual(scene);
    expect(result.fixtures.clock).not.toBeNull();
    await generateSceneArt(input);
    expect(draw).toHaveBeenCalledTimes(1);
    expect(authorSVG).toHaveBeenCalledTimes(2);
    expect(Buffer.from(vi.mocked(authorSVG).mock.calls[1][0].reference.bytes)).toEqual(reference);
    await result.clearCheckpoint();
    expect(store.objects.size).toBe(0);
  });

  it("does not redraw when checkpoint storage is unavailable", async () => {
    const store = new MemoryObjectStore(); setObjectStoreForTests(store);
    vi.spyOn(store, "get").mockRejectedValue(new Error("Storage unavailable"));
    const draw = vi.fn();
    await expect(generateSceneArt({ userId: "owner", kind: "themes", brief: "Park", style: null, draw })).rejects.toThrow("Storage unavailable");
    expect(draw).not.toHaveBeenCalled(); expect(authorSVG).not.toHaveBeenCalled();
  });

  it("pins an interrupted batch's engine and designs, and cleans all owner bundle files", async () => {
    const store = new MemoryObjectStore(); setObjectStoreForTests(store);
    const create = vi.fn(async () => ({ engine: "svg", designs: ["home"] }));
    await sceneDesignCheckpoint("owner", "rooms", "life", create);
    const resumed = await sceneDesignCheckpoint("owner", "rooms", "life", async () => ({ engine: "legacy", designs: ["different"] }));
    expect(resumed.value.engine).toBe("svg");
    await store.put("private/pet-rooms/other/safe.webp", { bytes: new Uint8Array(), contentType: "image/webp" });
    for (const extension of ["webp", "reference.png", "svg.json"]) await store.put(`private/pet-rooms/owner/art.${extension}`, { bytes: new Uint8Array(), contentType: "application/octet-stream" });
    await store.deletePrefix("private/pet-rooms/owner/");
    expect([...store.objects.keys()]).toEqual(["private/pet-rooms/other/safe.webp"]);
  });

  it("requires valid indoor windows, bindings and navigable geometry", () => {
    expect(SVGSceneSchema.safeParse({ ...scene, indoor: true }).success).toBe(true);
    expect(SVGSceneSchema.safeParse({ ...scene, effects: { ...scene.effects, lights: ["absent"] } }).success).toBe(false);
    expect(SVGSceneSchema.safeParse({ ...scene, indoor: true, effects: { ...scene.effects, windows: [] } }).success).toBe(false);
    expect(SVGSceneSchema.safeParse({ ...scene, spawn: { x: 0.01, y: 0.7 } }).success).toBe(false);
    expect(SVGSceneSchema.safeParse({ ...scene, walkable: [{x:0,y:0},{x:1,y:1},{x:0,y:1},{x:1,y:0}] }).success).toBe(false);
  });

  it("renders indoor precipitation only in the window", async () => {
    const rig = { ...scene.rig, groups: scene.rig.groups.filter(g => g.id === "weather") };
    const { data, info } = await sharp(Buffer.from(renderSVG(rig, { weather: "rainy" }))).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const alpha = (x: number, y: number) => data[(y * info.width + x) * 4 + 3];
    expect(alpha(30, 30)).toBe(255); expect(alpha(100, 100)).toBe(0);
  });
});
