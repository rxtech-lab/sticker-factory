import { afterEach, describe, expect, it } from "vitest";
import { Experimental_DecisionMockModelV4 as MockDecisionModel } from "ai/test";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { decideForPet } from "@/lib/ai/gateway-pet-decision";
import type { StickerConfiguration, StickerControl } from "@/lib/contracts/configuration";
import { describeCondition } from "@/lib/pets/condition";
import { posableControls, posePetForInteraction, poseQuestions, poseValues } from "@/lib/services/pet-pose";
import { touchMoment } from "@/lib/services/pet-touch";

const mood: StickerControl = { id: "mood", label: "Mood", type: "choice", defaultValue: "calm",
  options: [{ id: "calm", label: "Calm" }, { id: "giggle", label: "Giggling" }] };
const blush: StickerControl = { id: "blush", label: "Blush", type: "toggle", defaultValue: false, layerIds: ["cheeks"] };
const speed: StickerControl = { id: "speed", label: "Speed", type: "number", binding: "speed",
  defaultValue: 1, minimum: 0.25, maximum: 2, step: 0.25 };

describe("pet poses from the decision model", () => {
  it("poses choices and toggles, never speed", () => {
    expect(posableControls([mood, blush, speed]).map((control) => control.id)).toEqual(["mood", "blush"]);
  });

  it("asks a choice per choice control, away from what it holds, and a yes-or-no per toggle", () => {
    const questions = poseQuestions(posableControls([mood, blush]), { mood: "calm", blush: false });
    // Every interaction switches the pose: the option it holds now is not offered.
    expect(questions.mood).toMatchObject({ type: "choice", criteria: { giggle: "Giggling" } });
    expect(questions.mood.type === "choice" && Object.keys(questions.mood.criteria)).toEqual(["giggle"]);
    expect(questions.mood.instructions).toContain("\"Calm\" now");
    expect(touchMoment("tap")).toContain("tapped it gently");
    expect(questions.blush).toMatchObject({ type: "boolean", criteria: { true: "Blush on", false: "Blush off" } });
  });

  it("tells the decision model how the pet feels from its stats", () => {
    expect(describeCondition({ happiness: 80, energy: 90, hp: 100 }, 100)).toBe("full of energy, joyful");
    expect(describeCondition({ happiness: 20, energy: 10, hp: 100 }, 100)).toBe("exhausted and sleepy, unhappy and grumpy");
    expect(describeCondition({ happiness: 50, energy: 60, hp: 20 }, 100)).toBe("unwell and fragile, content");
    expect(describeCondition({ happiness: 50, energy: 60, hp: 90 }, 100, "a cold")).toBe("ill with a cold, content");
  });

  it("keeps only values the sticker has", () => {
    const controls = posableControls([mood, blush]);
    expect(poseValues(controls, {
      mood: { type: "choice", choice: "giggle" }, blush: { type: "boolean", probability: 0.2 },
    })).toEqual({ mood: "giggle", blush: false });
    expect(poseValues(controls, {
      mood: { type: "choice", choice: "furious" }, blush: { type: "boolean", probability: 0.9 },
    })).toEqual({ blush: true });
  });

  it("asks the decision model the touch's questions about the pet", async () => {
    let asked: unknown;
    const model = new MockDecisionModel({
      doDecide: async (options) => {
        asked = options;
        return { answers: { mood: { type: "choice", choice: "giggle" } }, warnings: [] };
      },
    });
    const answers = await decideForPet({ pet: "Bun" }, poseQuestions(posableControls([mood]), { mood: "calm" }), { model });
    expect(answers.mood).toMatchObject({ type: "choice", choice: "giggle" });
    expect(asked).toMatchObject({ state: { pet: "Bun" }, questions: { mood: { type: "choice" } } });
  });

  describe("after a user interaction", () => {
    const configuration = { controls: [mood, blush, speed], variants: [] } as unknown as StickerConfiguration;
    const moment = { petTitle: "Bun", identity: null, stats: { happiness: 50, energy: 50, hp: 10 }, moment: "Its owner fed it." };
    afterEach(() => setAiProviderForTests());

    it("poses with the decision model over the agent, which still sets speed", async () => {
      setAiProviderForTests(Object.assign(new MockAiProvider(), {
        decideForPet: async () => ({ mood: { type: "choice", choice: "giggle" }, blush: { type: "boolean", probability: 0.8 } }),
      }));
      const values = await posePetForInteraction(configuration, { mood: "calm" }, { mood: "calm", speed: 1.5 }, moment);
      expect(values).toEqual({ mood: "giggle", blush: true, speed: 1.5 });
    });

    it("keeps the agent's pose when the decision model fails", async () => {
      setAiProviderForTests(Object.assign(new MockAiProvider(), {
        decideForPet: async () => { throw new Error("gateway down"); },
      }));
      const values = await posePetForInteraction(configuration, { mood: "calm" }, { mood: "giggle" }, moment);
      expect(values).toEqual({ mood: "giggle", blush: false, speed: 1 });
    });
  });
});
