import { afterEach, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import sharp from "sharp";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { SVGAnimationRigSchema } from "@/lib/contracts/controllable";
import { authorSVG } from "@/lib/ai/gateway-svg";
import { setDatabaseForTests } from "@/lib/db/client";
import { generationJobs } from "@/lib/db/schema";
import { downcastForClient, resolveStickerConfiguration } from "@/lib/contracts/sticker";
import { renderSticker } from "@/lib/render/sticker-render";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";
import { SVGControllableEngine } from "@/workflows/sticker-generation/controllable-engine";
import { documentFromPlan } from "@/workflows/sticker-generation/asset-generation";

vi.mock("@/lib/ai/gateway-svg", () => ({ authorSVG: vi.fn(), SVGArtworkValidationError: class extends Error {} }));
afterEach(() => { setDatabaseForTests(undefined); vi.resetAllMocks(); });

it("builds SVG from approved pixels, checkpoints it, and keeps controls and poster exports", async () => {
  const { db, close } = await createTestDatabase(); setDatabaseForTests(db);
  try {
    await seedUser(db, "owner");
    const sticker = await seedPublishedSticker(db, "owner", { kind: "animated", controllable: true });
    const [job] = await db.insert(generationJobs).values({ id: crypto.randomUUID(), ownerId: "owner", stickerId: sticker.stickerId, kind: "compose", state: "running", controllableEngine: "svg" }).returning();
    const plan = PlanV1Schema.parse({ engine: "svg", title: "Cat", summary: "Moods and walking", kind: "animated", timing: { durationSeconds: 2, fps: 24, loop: "loop" },
      layers: [{ layerId: "hero", name: "Cat", x: .5, y: .5, scaleX: 1, scaleY: 1, source: { kind: "sprite", prompt: "The approved cat", face: "Face at the center of the head",
        clips: ["idle", "walk"].map(id => ({ id, label: id, prompt: id, frames: [{ duration: 1 }] })),
        expressions: ["calm", "happy"].map(id => ({ id, label: id, prompt: id })) } }],
      configuration: { controls: [
        { id: "mood", label: "Mood", type: "choice", defaultValue: "calm", options: ["calm", "happy"].map(id => ({ id, label: id })) },
        { id: "pose", label: "Pose", type: "choice", defaultValue: "idle", options: ["idle", "walk"].map(id => ({ id, label: id })) }], variants: [
          ...["calm", "happy"].map(id => ({ id, selections: { mood: id }, layers: [{ layerId: "hero", expression: id }] })),
          ...["idle", "walk"].map(id => ({ id, selections: { pose: id }, layers: [{ layerId: "hero", clip: id }] }))] } });
    const rig = SVGAnimationRigSchema.parse(JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-svg-parity.json", import.meta.url), "utf8")).rig);
    rig.groups[0].when = { pose: ["idle", "walk"] };
    rig.groups.find(g => g.id === "face")!.when = { expression: ["calm", "happy"] };
    const reference = { bytes: await sharp({ create: { width: 200, height: 200, channels: 4, background: "#FFD080" } }).png().toBuffer(), mimeType: "image/png" as const };
    const engine = new SVGControllableEngine(); engine.validate(plan);
    const input = { job, stickerId: sticker.stickerId, plan, assetJobId: job.id, reference, summary: undefined, stayPut: true };
    vi.mocked(authorSVG).mockRejectedValueOnce(new Error("Invalid vector artwork"));
    await expect(engine.generate(input)).rejects.toThrow("Invalid vector artwork");
    vi.mocked(authorSVG).mockResolvedValueOnce(rig);
    const builds = await engine.generate(input);
    const document = documentFromPlan(plan, job.id, new Map(), builds);
    expect(document.layers[0]).toMatchObject({ type: "svg", rig });
    expect(resolveStickerConfiguration(document, { mood: "happy", pose: "walk" }).layers[0]).toMatchObject({ svgState: { expression: "happy", pose: "walk" } });
    const replay = await engine.generate(input);
    expect(replay).toEqual(builds); expect(authorSVG).toHaveBeenCalledTimes(2);
    expect(vi.mocked(authorSVG).mock.calls[1][0].reference).toEqual(reference);
    const poster = builds.get("hero")!.posterAssetId;
    expect(downcastForClient(document, 7)).toMatchObject({ layers: [{ type: "image", assetId: poster }] });
    const rendered = await renderSticker(document, new Map([[poster, reference]]));
    expect(rendered.times).toHaveLength(6); expect(rendered.bytes.length).toBeGreaterThan(1000);
  } finally { await close(); }
});
