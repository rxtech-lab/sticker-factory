import { afterEach, describe, expect, it, vi } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { AiPetPoseContext } from "@/lib/ai/gateway-contracts";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { petAgentModelId, petDecisionModelId } from "@/lib/ai/pet-models";
import { StickerConfigurationSchema } from "@/lib/contracts/configuration";
import { setPetRandomForTests } from "@/lib/pets/log";
import { settlePetMemoriesForTests } from "@/lib/services/pet-memory";
import { posePetForTalk } from "@/lib/services/pet-talk";
import { setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

class RecordingProvider extends MockAiProvider {
  asked: AiPetPoseContext[] = [];
  override async decidePetPose(input: AiPetPoseContext) {
    this.asked.push(input);
    return super.decidePetPose(input);
  }
}

describe("pet pose for talk", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setAiProviderForTests(undefined);
    vi.unstubAllEnvs();
  });

  it("poses the pet to match what its owner said", async () => {
    setPetRandomForTests(() => 0.5);
    const ai = new RecordingProvider();
    setAiProviderForTests(ai);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    try {
      await seedUser(db, "owner");
      const configuration = StickerConfigurationSchema.parse({
        controls: [{ id: "mood", label: "Mood", type: "choice", defaultValue: "calm",
          options: [{ id: "calm", label: "Calm" }, { id: "happy", label: "Happy" }] }],
        variants: [],
      });
      const loaf = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true, configuration });
      const adopted = await setPet(db, "owner", { stickerId: loaf.stickerId });
      await settlePetMemoriesForTests();

      const { pet } = await posePetForTalk(db, "owner", { words: "You make me so happy", reply: "Yay!" }, async () => {});
      expect(ai.asked[0]).toMatchObject({ words: "You make me so happy", reply: "Yay!", petTitle: "Loaf" });
      expect(pet!.status!.values).toMatchObject({ mood: "happy" });
      // A pet with no line yet takes its answer as one.
      expect(adopted.pet!.status).toBeNull();
      expect(pet!.status!.caption).toBe("Yay!");
      expect(pet!.status!.animateEverySeconds).toBe(20);
    } finally {
      await close();
    }
  });

  it("reads the pet's models from their own env, falling back to the old ones", () => {
    vi.stubEnv("AI_PET_AGENT_MODEL", "");
    vi.stubEnv("AI_SUMMARY_MODEL", "openai/summary");
    delete process.env.AI_PET_AGENT_MODEL;
    delete process.env.AI_PET_DECISION_MODEL;
    expect(petAgentModelId()).toBe("openai/summary");
    expect(petDecisionModelId()).toBe("openai/summary");
    vi.stubEnv("AI_PET_AGENT_MODEL", "anthropic/agent");
    vi.stubEnv("AI_PET_DECISION_MODEL", "google/fast");
    expect(petAgentModelId()).toBe("anthropic/agent");
    expect(petDecisionModelId()).toBe("google/fast");
  });
});
