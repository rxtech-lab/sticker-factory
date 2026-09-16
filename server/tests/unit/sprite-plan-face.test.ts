import { expect, it } from "vitest";
import { assertSpriteFaces, PlanV1Schema } from "@/lib/contracts/plan";

const sprite = (face?: string) => ({
  layerId: "hero", name: "Car", x: 0.5, y: 0.5, scaleX: 1, scaleY: 1, source: {
    kind: "sprite", prompt: "A red cartoon car", ...(face ? { face } : {}),
    clips: [{ id: "idle", label: "Idle", prompt: "rocks gently", frames: [{ duration: 1 }] }],
    expressions: [{ id: "neutral", label: "Neutral", prompt: "calm eyes" }, { id: "happy", label: "Happy", prompt: "wide smile" }],
  },
});
const plan = (layers: unknown[]) => PlanV1Schema.parse({
  title: "Car", summary: "A controllable car", kind: "animated", timing: { durationSeconds: 3, fps: 24, loop: "loop" }, layers,
  configuration: { controls: [
    { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }] },
  ], variants: [
    { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
    { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
  ] },
});

it("keeps the face region on the sprite source and still parses plans stored without one", () => {
  const withFace = plan([sprite("the windshield: both eyes and the mouth are inside the glass")]);
  const source = withFace.layers[0].source;
  expect(source.kind === "sprite" && source.face).toBe("the windshield: both eyes and the mouth are inside the glass");
  expect(() => assertSpriteFaces(withFace)).not.toThrow();
  // Older stored plans predate `face`; the schema alone must not reject them.
  const legacy = plan([sprite()]);
  expect(legacy.layers[0].source).not.toHaveProperty("face");
});

it("refuses to draft a sprite whose face region is not named, naming the layer", () => {
  expect(() => assertSpriteFaces(plan([sprite()]))).toThrow(/Sprite hero needs `face`.*windshield/);
  expect(() => assertSpriteFaces({ layers: [] })).not.toThrow();
});
