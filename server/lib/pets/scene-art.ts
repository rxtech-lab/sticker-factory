import { createHash } from "node:crypto";
import sharp from "sharp";
import type { AiImageOutput, AiReferenceImage } from "@/lib/ai/gateway-contracts";
import { authorSVG } from "@/lib/ai/gateway-svg";
import { SVGSceneSchema, type SVGScene } from "@/lib/contracts/controllable";
import type { PetRoomFixtures } from "@/lib/db/schema";
import { getObjectStore } from "@/lib/storage/r2";
import { traceEvent } from "@/lib/observability/trace";

/** Saved reference and completed SVG use separate keys so conversion retries never redraw the image. */
export async function generateSceneArt(input: {
  userId: string; kind: "rooms" | "themes"; brief: string; style: AiReferenceImage | null;
  draw: () => Promise<AiImageOutput>;
}): Promise<{ bytes: Buffer; scene: SVGScene; fixtures: PetRoomFixtures; referenceBytes: Uint8Array; clearCheckpoint: () => Promise<void> }> {
  const hash = createHash("sha256").update(input.brief).update(input.style?.bytes ?? new Uint8Array()).digest("hex");
  const prefix = `private/pet-${input.kind}/${input.userId}/pending-${hash}`;
  const store = getObjectStore();
  const read = async (key: string) => { try { return await store.get(key); } catch (error) {
    // Missing is recoverable; storage outages must not trigger a second paid image generation.
    const name = error instanceof Error ? error.name : "";
    if (["NoSuchKey", "NotFound", "ObjectNotFound"].includes(name) || (error as { status?: number }).status === 404 || String(error).includes("not found")) return null;
    throw error;
  } };
  const started = Date.now();
  traceEvent("scene:reference:start", { engine: "svg", kind: input.kind });
  let reference = await read(`${prefix}.png`);
  if (!reference) {
    const image = await input.draw();
    reference = { bytes: await sharp(image.bytes).png().toBuffer(), contentType: "image/png" };
    await store.put(`${prefix}.png`, reference);
  }
  traceEvent("scene:reference:ready", { engine: "svg", kind: input.kind, durationMs: Date.now() - started });
  const cached = await read(`${prefix}.json`);
  const scene = cached ? SVGSceneSchema.parse(JSON.parse(Buffer.from(cached.bytes).toString("utf8")))
    : SVGSceneSchema.parse(await authorSVG({ reference: { bytes: reference.bytes, mimeType: "image/png" }, scene: true,
      brief: `${input.brief}. ${input.kind === "rooms" ? "This is an indoor room. indoor=true." : "Determine whether this place is indoor or outdoor from the reference."} Preserve the reference composition.` }));
  if (!cached) await store.put(`${prefix}.json`, { bytes: Buffer.from(JSON.stringify(scene)), contentType: "application/json" });
  traceEvent("scene:svg:ready", { engine: "svg", kind: input.kind, reused: !!cached, durationMs: Date.now() - started });
  const bytes = await sharp(reference.bytes).webp({ quality: 90 }).toBuffer();
  const fixture = (point: { x: number; y: number } | null) => point ? { x: Math.max(0, point.x - 0.045), y: Math.max(0, point.y - 0.04), width: 0.09, height: 0.08, shape: "rect" as const, face: "#F6ECD7", ink: "#332E29" } : null;
  return { bytes, scene, referenceBytes: reference.bytes, clearCheckpoint: async () => { await store.delete(`${prefix}.png`); await store.delete(`${prefix}.json`); }, fixtures: { clock: fixture(scene.fixtures.clock), weather: fixture(scene.fixtures.weather), status: fixture(scene.fixtures.status) } };
}

/** Retains an entire batch's design across failed conversions; the batch is published together. */
export async function sceneDesignCheckpoint<T>(userId: string, kind: "rooms" | "themes", identity: string, draw: () => Promise<T>): Promise<{ value: T; clear: () => Promise<void> }> {
  const key = `private/pet-${kind}/${userId}/pending-design-${createHash("sha256").update(identity).digest("hex")}.json`;
  const store = getObjectStore();
  let bytes: Uint8Array | undefined;
  try { bytes = (await store.get(key)).bytes; } catch (error) {
    if ((error as { status?: number }).status !== 404 && !["NoSuchKey", "NotFound"].includes(error instanceof Error ? error.name : "")) throw error;
  }
  const value: T = bytes ? JSON.parse(Buffer.from(bytes).toString("utf8")) : await draw();
  if (!bytes) await store.put(key, { bytes: Buffer.from(JSON.stringify(value)), contentType: "application/json" });
  return { value, clear: () => store.delete(key) };
}
