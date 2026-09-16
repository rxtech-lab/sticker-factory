import { afterEach, expect, it, vi } from "vitest";
import sharp from "sharp";
import { inspectSpriteSheet } from "@/lib/ai/gateway-images";

const { generateText } = vi.hoisted(() => ({ generateText: vi.fn() }));
vi.mock("ai", async (importOriginal) => ({ ...await importOriginal<typeof import("ai")>(), generateText }));
vi.mock("@/lib/ai/cost", () => ({ recordTextApiCost: vi.fn(), reportAiStepUsage: vi.fn() }));
afterEach(() => { generateText.mockReset(); });

const image = async () => ({
  bytes: new Uint8Array(await sharp({ create: { width: 128, height: 128, channels: 4, background: "white" } }).png().toBuffer()),
  mimeType: "image/png" as const,
});
const textOf = (call: { messages: Array<{ content: Array<{ type: string; text?: string }> }> }) =>
  call.messages[0].content.find((part) => part.type === "text")!.text!;

it("shows the body sheet with its face region and returns the inspector's problems", async () => {
  generateText.mockResolvedValueOnce({ toolCalls: [{ toolName: "report_sheet", input: { ok: false, problems: [" cell 2 keeps a mouth on the bumper "] } }] });
  const verdict = await inspectSpriteSheet({
    kind: "clips", character: "Car", face: "the windshield", sheet: { columns: 3, rows: 2, count: 6 }, image: await image(),
  });
  expect(verdict).toEqual({ ok: false, problems: ["cell 2 keeps a mouth on the bumper"] });
  const call = generateText.mock.calls[0][0];
  const text = textOf(call);
  expect(text).toContain("Character: Car. Face region: the windshield.");
  expect(text).toContain("3 columns by 2 rows; the first 6 cells are used");
  expect(text).toContain("outside that oval");
  expect(call.messages[0].content.filter((part: { type: string }) => part.type === "image")).toHaveLength(1);
  expect(call.toolChoice).toBe("required");
  expect(Object.keys(call.tools)).toEqual(["report_sheet"]);
});

it("lists the planned expressions in order for a face-plate sheet and accepts a clean report", async () => {
  generateText.mockResolvedValueOnce({ toolCalls: [{ toolName: "report_sheet", input: { ok: true, problems: [] } }] });
  const verdict = await inspectSpriteSheet({
    kind: "expressions", character: "Car", sheet: { columns: 2, rows: 2, count: 3 }, image: await image(),
    expressions: ["Neutral", "Excited", "Surprised"], faceGuide: await image(),
  });
  expect(verdict).toEqual({ ok: true });
  const text = textOf(generateText.mock.calls[0][0]);
  expect(text).toContain("Face region: the character's head, where the eyes and mouth are.");
  expect(text).toContain("1. Neutral; 2. Excited; 3. Surprised");
  expect(text).toContain("only an inner face patch");
  expect(text).toContain("Image 2 is the actual body frame");
  expect(text).toContain("Reject actual enclosing head outlines");
  expect(generateText.mock.calls[0][0].messages[0].content.filter((part: { type: string }) => part.type === "image")).toHaveLength(2);
});

it("fails loudly when the inspector never reports", async () => {
  generateText.mockResolvedValueOnce({ toolCalls: [] });
  await expect(inspectSpriteSheet({
    kind: "clips", character: "Car", sheet: { columns: 3, rows: 2, count: 6 }, image: await image(),
  })).rejects.toThrow("report_sheet");
});
