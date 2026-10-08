import { afterEach, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { generateText } from "ai";
import { authorSVG, SVGArtworkValidationError, stillPoses, unboundStates, type SVGAuthoringProgress } from "@/lib/ai/gateway-svg";

vi.mock("@ai-sdk/gateway", () => ({ gateway: vi.fn() }));
vi.mock("ai", () => ({ generateText: vi.fn(), Output: { object: vi.fn() } }));
vi.mock("@/lib/ai/text-model", () => ({ orchestratorModel: vi.fn(), svgAuthoringModel: vi.fn() }));
const rig = JSON.parse(readFileSync(new URL("../../../StickerGeniOS/packages/AnimatedView/Tests/AnimatedViewTests/Fixtures/controllable-svg-parity.json", import.meta.url), "utf8")).rig;
const input = { reference: { bytes: new Uint8Array([1]), mimeType: "image/png" as const }, brief: "Cat", scene: false };
const result = (output: unknown) => ({ output, usage: { outputTokens: 10 }, steps: [] }) as never;
type Rig = typeof rig;
const entries = (when: Record<string, unknown[]>) => Object.entries(when).map(([key, values]) => ({ key, values }));
/** The list-shaped form the model writes (lib/ai/svg-wire.ts). */
const toWire = (r: Rig) => ({
  ...r,
  defaults: Object.entries(r.defaults).map(([key, value]) => ({ key, value })),
  groups: r.groups.map((g: Rig["groups"][number]) => ({ ...g, when: entries(g.when), colors: g.colors.map((c: { when: Record<string, unknown[]> }) => ({ ...c, when: entries(c.when) })) })),
  emotions: Object.entries(r.emotions).map(([expression, emotion]) => ({ expression, emotion })),
});
const drawn = (r: Rig) => result(toWire(r));
afterEach(() => vi.resetAllMocks());

it("reports the failed validation, retry and successful review as separate steps", async () => {
  const still = structuredClone(rig);
  for (const group of still.groups) group.tracks = [];
  vi.mocked(generateText).mockResolvedValueOnce(drawn(still)).mockResolvedValueOnce(drawn(rig))
    .mockResolvedValueOnce(result({ approved: true, corrections: [] }));
  const events: SVGAuthoringProgress[] = [];
  await authorSVG({ ...input, onProgress: async event => { events.push(event); } });
  expect(events.map(e => `${e.attempt}:${e.stage}:${e.status}`)).toEqual([
    "1:authoring:started", "1:authoring:complete", "1:validation:started", "1:validation:failed",
    "2:authoring:started", "2:authoring:complete", "2:validation:started", "2:validation:complete", "2:review:started", "2:review:complete",
  ]);
  expect(events[3].message).toContain("animated artwork");
  expect(events.every(e => e.durationMs >= 0 && e.maxAttempts === 3)).toBe(true);
});

it("does not expose provider response bodies in failure cards", async () => {
  vi.mocked(generateText).mockRejectedValue(new Error("Provider rejected api_key=private-secret and request body"));
  const events: SVGAuthoringProgress[] = [];
  await expect(authorSVG({ ...input, onProgress: async event => { events.push(event); } })).rejects.toThrow();
  expect(events.filter(e => e.status === "failed")).toHaveLength(3);
  expect(JSON.stringify(events)).not.toContain("private-secret");
});

it("stops instead of purchasing another attempt when progress reporting cancels the job", async () => {
  vi.mocked(generateText).mockResolvedValue(drawn(rig));
  await expect(authorSVG({ ...input, onProgress: async event => {
    if (event.stage === "validation") throw new Error("Generation cancelled");
  } })).rejects.toThrow("Generation cancelled");
  expect(generateText).toHaveBeenCalledTimes(1);
});

it("keeps the final structurally valid artwork instead of failing the job over review polish", async () => {
  const rejected = result({ approved: false, corrections: ["Match the pixel-art shading"] });
  vi.mocked(generateText).mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(rejected)
    .mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(rejected)
    .mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(rejected);
  const events: SVGAuthoringProgress[] = [];
  await expect(authorSVG({ ...input, onProgress: async event => { events.push(event); } })).resolves.toBeTruthy();
  expect(events.at(-1)).toMatchObject({ attempt: 3, stage: "review", status: "complete" });
  expect(generateText).toHaveBeenCalledTimes(6);
});

it("keeps validated artwork when the reviewer cannot return a readable verdict", async () => {
  vi.mocked(generateText).mockResolvedValueOnce(drawn(rig))
    .mockRejectedValueOnce(Object.assign(new Error("No object generated"), { name: "AI_NoObjectGeneratedError" }))
    .mockRejectedValueOnce(Object.assign(new Error("No object generated"), { name: "AI_NoObjectGeneratedError" }));
  const events: SVGAuthoringProgress[] = [];
  await expect(authorSVG({ ...input, onProgress: async event => { events.push(event); } })).resolves.toBeTruthy();
  expect(events.at(-1)).toMatchObject({ attempt: 1, stage: "review", status: "complete" });
  expect(generateText).toHaveBeenCalledTimes(3);
});

it("flags poses whose only motion is too small to see in a thumbnail", () => {
  const jitter = { property: "y", duration: 2, loop: true, interpolation: "linear", frames: [{ time: 0, value: 0 }, { time: 1, value: -3 }, { time: 2, value: 0 }] };
  const swing = { ...jitter, property: "rotation", frames: [{ time: 0, value: 0 }, { time: 1, value: 8 }, { time: 2, value: 0 }] };
  const tiny = { ...structuredClone(rig), width: 1024, height: 1024, groups: [
    { ...rig.groups[0], id: "idle", when: { pose: ["idle"] }, tracks: [jitter] },
    { ...rig.groups[0], id: "walk", when: { pose: ["walk"] }, tracks: [jitter, swing] },
  ] };
  expect(stillPoses(tiny, ["idle", "walk"])).toEqual(["idle"]);
  expect(stillPoses(rig, ["idle"])).toEqual([]);
});

it("accepts a default pose drawn only by unconditional groups, but no other unbound state", () => {
  const base = { ...structuredClone(rig), defaults: { ...rig.defaults, pose: "idle" }, groups: [
    { ...rig.groups[0], id: "body", when: {} },
    { ...rig.groups[0], id: "legs", when: { pose: ["walk"] } },
  ] };
  expect(unboundStates(base, { pose: ["idle", "walk", "typing"] })).toEqual(["pose typing"]);
  expect(unboundStates({ ...base, defaults: { ...base.defaults, pose: "walk" } }, { pose: ["idle"] })).toEqual(["pose idle"]);
});

it("keeps every earlier failure in the repair prompt", async () => {
  const still = structuredClone(rig);
  for (const group of still.groups) group.tracks = [];
  vi.mocked(generateText).mockResolvedValueOnce(drawn(still))
    .mockRejectedValueOnce(new SVGArtworkValidationError("second problem"))
    .mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(result({ approved: true, corrections: [] }));
  await authorSVG(input);
  const prompt = JSON.stringify(vi.mocked(generateText).mock.calls[2][0].messages);
  expect(prompt).toContain("animated artwork");
  expect(prompt).toContain("second problem");
});

it("repairs the previous drawing instead of redrawing from scratch", async () => {
  const still = structuredClone(rig);
  for (const group of still.groups) group.tracks = [];
  vi.mocked(generateText).mockResolvedValueOnce(drawn(still))
    .mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(result({ approved: true, corrections: [] }));
  await authorSVG(input);
  const messages = vi.mocked(generateText).mock.calls[1][0].messages!;
  expect(messages.map(m => m.role)).toEqual(["user", "assistant", "user"]);
  expect(messages[1].content).toBe(JSON.stringify(toWire(still)));
  expect(JSON.stringify(messages[2].content)).toContain("animated artwork");
  expect(JSON.stringify(vi.mocked(generateText).mock.calls[0][0].messages)).not.toContain("rejected");
});

it("names the group a schema failure came from", async () => {
  const unsafe = structuredClone(rig);
  unsafe.groups[0].markup = unsafe.groups[0].markup.replace("<svg ", "<svg style=\"x\" ");
  vi.mocked(generateText).mockResolvedValueOnce(drawn(unsafe))
    .mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(result({ approved: true, corrections: [] }));
  const events: SVGAuthoringProgress[] = [];
  await authorSVG({ ...input, onProgress: async event => { events.push(event); } });
  expect(events.find(e => e.status === "failed")?.message).toContain("groups.0.markup: Unsupported or unsafe vector markup");
});

it("turns the list-shaped bindings the model writes back into the rig contract", async () => {
  vi.mocked(generateText).mockResolvedValueOnce(drawn(rig)).mockResolvedValueOnce(result({ approved: true, corrections: [] }));
  await expect(authorSVG(input)).resolves.toEqual(rig);
});
