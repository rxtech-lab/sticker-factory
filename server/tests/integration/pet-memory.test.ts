import { eq } from "drizzle-orm";
import { afterEach, describe, expect, it } from "vitest";
import { setAiProviderForTests } from "@/lib/ai/gateway";
import type { AiPetInteractionContext, AiPetMemoryContext, AiPetMemoryOperation } from "@/lib/ai/gateway-contracts";
import { MockAiProvider } from "@/lib/ai/gateway-mock";
import { PetMemoriesResponseV1Schema } from "@/lib/contracts/api";
import { petMemories } from "@/lib/db/schema";
import { setPetRandomForTests } from "@/lib/pets/log";
import { listPetMemories, rememberPetTalk, settlePetMemoriesForTests } from "@/lib/services/pet-memory";
import { clearPet, getPet, interactWithPet, setPet } from "@/lib/services/pets";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedPublishedSticker, seedUser } from "@/tests/helpers/packs";

/** The mock, recording what the pet was reminded of and what its memory agent was shown. */
class RecordingProvider extends MockAiProvider {
  recalled: string[][] = [];
  shown: AiPetMemoryContext[] = [];
  decide?: (input: AiPetMemoryContext) => AiPetMemoryOperation[];

  override async respondToPetInteraction(input: AiPetInteractionContext) {
    this.recalled.push(input.memories ?? []);
    return super.respondToPetInteraction(input);
  }

  override async updatePetMemory(input: AiPetMemoryContext) {
    this.shown.push(input);
    return this.decide?.(input) ?? super.updatePetMemory(input);
  }
}

describe("pet memory", () => {
  afterEach(() => {
    setObjectStoreForTests(undefined);
    setPetRandomForTests(undefined);
    setAiProviderForTests(undefined);
  });

  async function setup() {
    setPetRandomForTests(() => 0.5);
    const ai = new RecordingProvider();
    setAiProviderForTests(ai);
    const { db, close } = await createTestDatabase();
    setObjectStoreForTests(new MemoryObjectStore());
    await seedUser(db, "owner");
    const loaf = await seedPublishedSticker(db, "owner", { title: "Loaf", kind: "animated", controllable: true });
    const adopted = await setPet(db, "owner", { stickerId: loaf.stickerId });
    await settlePetMemoriesForTests();
    return { db, close, ai, loaf, adopted };
  }

  it("remembers its adoption and every interaction, and is reminded of them when it answers", async () => {
    const { db, close, ai, adopted } = await setup();
    try {
      const first = await listPetMemories(db, "owner", { limit: 20 });
      expect(first.memories.map((memory) => memory.content)).toEqual([expect.stringContaining("Adopted Loaf")]);

      const greet = adopted.pet!.actions[0];
      await interactWithPet(db, "owner", { actionId: greet.id }, async () => {});
      await settlePetMemoriesForTests();
      const afterGreet = PetMemoriesResponseV1Schema.parse(await listPetMemories(db, "owner", { limit: 20 }));
      expect(afterGreet.memories).toHaveLength(2);
      // It was already reminded of being adopted when it answered.
      expect(ai.recalled[0]).toEqual([expect.stringContaining("Adopted Loaf")]);

      // The same moment again is found by meaning and folded into what it remembers, not added twice.
      const again = (await getPet(db, "owner")).pet!.actions.find((action) => action.title === greet.title)!;
      await interactWithPet(db, "owner", { actionId: again.id }, async () => {});
      await settlePetMemoriesForTests();
      const afterAgain = await listPetMemories(db, "owner", { limit: 20 });
      expect(afterAgain.memories).toHaveLength(2);
      expect(afterAgain.memories[0]).toMatchObject({ content: expect.stringContaining(greet.description), importance: 3 });
      expect(ai.shown.at(-1)!.memories.map((memory) => memory.content)).toContain(afterAgain.memories[0].content);
      expect(ai.recalled[1][0]).toContain(greet.description);
    } finally {
      await close();
    }
  });

  it("remembers what its owner said, and finds it by meaning", async () => {
    const { db, close } = await setup();
    try {
      await rememberPetTalk(db, "owner", { words: "My favourite food is strawberry cake", reply: "Cake! Yum!" });
      await settlePetMemoriesForTests();
      const found = await listPetMemories(db, "owner", { query: "what food does the owner like? strawberry cake", limit: 1 });
      expect(found.memories).toEqual([expect.objectContaining({ category: "owner", content: expect.stringContaining("strawberry cake") })]);
    } finally {
      await close();
    }
  });

  it("only rewrites or forgets memories its agent was shown", async () => {
    const { db, close, ai, adopted } = await setup();
    try {
      const [adoption] = (await listPetMemories(db, "owner", { limit: 20 })).memories;
      ai.decide = () => [
        { op: "update", id: "made-up", content: "Never happened", category: "bond", importance: 5 },
        { op: "delete", id: adoption.id },
        { op: "add", content: "Its owner greets it every morning", category: "bond", importance: 4 },
      ];
      await interactWithPet(db, "owner", { actionId: adopted.pet!.actions[0].id }, async () => {});
      await settlePetMemoriesForTests();
      const rows = await db.select().from(petMemories).where(eq(petMemories.userId, "owner"));
      expect(rows.map((row) => row.content)).toEqual(["Its owner greets it every morning"]);
      expect(rows[0].sourcesJson).toEqual([expect.objectContaining({ kind: "interaction", title: adopted.pet!.actions[0].title })]);
    } finally {
      await close();
    }
  });

  it("starts a new pet with no memories of the last one", async () => {
    const { db, close, loaf } = await setup();
    try {
      await rememberPetTalk(db, "owner", { words: "Good night, Loaf" });
      await settlePetMemoriesForTests();
      await clearPet(db, "owner");
      await setPet(db, "owner", { stickerId: loaf.stickerId });
      await settlePetMemoriesForTests();
      const memories = (await listPetMemories(db, "owner", { limit: 20 })).memories;
      expect(memories.map((memory) => memory.content)).toEqual([expect.stringContaining("Adopted Loaf")]);
    } finally {
      await close();
    }
  });
});
