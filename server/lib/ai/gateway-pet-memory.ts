// The pet's memory: embeddings for finding what it remembers by meaning, and the agent that decides
// what it remembers after each moment with its owner.

import { gateway } from "@ai-sdk/gateway";
import { embedMany, generateText, hasToolCall, stepCountIs, tool } from "ai";
import { z } from "zod";
import { recordTextApiCost, reportAiStepUsage } from "@/lib/ai/cost";
import { PET_MEMORY_CATEGORIES } from "@/lib/contracts/api";
import type { AiPetMemoryContext, AiPetMemoryOperation } from "./gateway-contracts";
import { userTurn } from "./gateway-models";
import { petAgentModel } from "./pet-models";
import { describeIdentity } from "./gateway-pet";

/** The model every memory is embedded with; its width is `PET_MEMORY_DIMENSIONS`. */
const PET_MEMORY_EMBEDDING_MODEL = "openai/text-embedding-3-small";

export async function embedPetMemories(values: string[]): Promise<number[][]> {
  if (!values.length) return [];
  const result = await embedMany({
    model: gateway.embeddingModel(PET_MEMORY_EMBEDDING_MODEL),
    values,
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(20_000),
  });
  return result.embeddings;
}

export const PET_MEMORY_OPERATIONS_MAX = 6;

const PetMemoryContentSchema = z.string().trim().min(1).max(200);
const PetMemoryInputSchema = z.object({ operations: z.array(z.discriminatedUnion("op", [
  z.object({ op: z.literal("add"), content: PetMemoryContentSchema, category: z.enum(PET_MEMORY_CATEGORIES),
    importance: z.number().int().min(1).max(5) }).strict(),
  z.object({ op: z.literal("update"), id: z.string().min(1), content: PetMemoryContentSchema,
    category: z.enum(PET_MEMORY_CATEGORIES), importance: z.number().int().min(1).max(5) }).strict(),
  z.object({ op: z.literal("delete"), id: z.string().min(1) }).strict(),
])).max(PET_MEMORY_OPERATIONS_MAX) }).strict();

/**
 * The pet's memory agent: reads what just happened beside the memories nearest to it, and keeps
 * the pet's picture of its owner and its life current — a new note for something worth keeping, a
 * rewrite when something it knew changed or grew, a deletion when it is no longer true.
 */
export async function updatePetMemory(input: AiPetMemoryContext): Promise<AiPetMemoryOperation[]> {
  const result = await generateText({
    onLanguageModelCallEnd: reportAiStepUsage,
    // Runs in the background after every moment, so it takes the cheap model.
    model: petAgentModel(),
    system: [
      "You keep the long-term memory of a user's virtual pet. You are given what just happened between the pet",
      "and its owner, and the memories the pet already has that are closest to it. Decide what the pet should",
      "remember from now on, answering only through update-memory, exactly once.",
      "Remember what will still matter later: the owner's name, likes, habits, plans and feelings; shared",
      "rituals and favourite activities; gifts and who gave them; rooms and places the pet has lived or been;",
      "how the pet has come to feel about things. Skip routine bookkeeping such as gold totals or stat numbers.",
      "Prefer updating an existing memory over adding a near-duplicate: fold the new moment into it (\"Loves",
      "dancing with its owner — they have danced together many times\"). Delete a memory only when the moment",
      "shows it is no longer true. Only use ids from the memories listed. Write each memory as one short",
      "sentence in the third person about the pet (\"Its owner…\", \"It…\"), at most 200 characters, in the",
      "language the owner speaks in the moments. Importance runs 1 (a passing detail) to 5 (never forget).",
      `At most ${PET_MEMORY_OPERATIONS_MAX} operations; an empty list when nothing is worth remembering.`,
    ].join(" "),
    messages: userTurn([
      `Pet: ${input.petTitle}`,
      describeIdentity(input.identity),
      `What just happened:\n${input.moments.map((moment) => `- [${moment.at}] (${moment.kind}) ${moment.title}: ${moment.detail}`).join("\n")}`,
      input.memories.length
        ? `Closest memories:\n${input.memories.map((memory) => `- id ${memory.id} [${memory.category}, importance ${memory.importance}]: ${memory.content}`).join("\n")}`
        : "Closest memories: none yet",
    ].join("\n\n"), []),
    tools: { "update-memory": tool({
      description: "Add, rewrite or forget the pet's memories.",
      inputSchema: PetMemoryInputSchema,
      execute: async (value) => value,
    }) },
    toolChoice: "required",
    stopWhen: [hasToolCall("update-memory"), stepCountIs(2)],
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(45_000),
  });
  await recordTextApiCost(result);
  const call = result.toolCalls.find((candidate) => candidate?.toolName === "update-memory");
  if (!call) throw new Error("Pet agent did not update its memory");
  return PetMemoryInputSchema.parse(call.input).operations;
}
