// The conversational turns: routing what the user asked for, and the short replies that
// narrate a turn once it is done.

import { gateway } from "@ai-sdk/gateway";
import { generateText, tool, type LanguageModel } from "ai";
import { z } from "zod";
import { recordTextApiCost } from "@/lib/ai/cost";
import { resolveChatAction } from "./gateway-contracts";
import type { AiChatAction, AiChatContext, AiTitleContext } from "./gateway-contracts";
import { attachedImagesNote, priorArtNote, userTurn, viewablePlanVisuals, viewableReferences } from "./gateway-models";

export async function routeChatTurn(input: AiChatContext, chatModel?: LanguageModel): Promise<AiChatAction> {
  const priorArt = await viewablePlanVisuals(input.priorArt);
  const viewable = await viewableReferences(input.references);
  const videoLayers = input.stickerKind === "animated" && input.document?.kind === "animated"
    && !input.document.layers.some((layer) => layer.type === "video")
    ? input.document.layers.filter((layer) => layer.type === "image")
    : [];
  const videoInput = z.object({
    layerId: z.enum(videoLayers.length > 0 ? videoLayers.map((layer) => layer.id) : ["unavailable"]),
    motion: z.string().trim().min(1).max(500),
    durationSeconds: z.number().int().min(2).max(4).default(3),
  }).strict();
  const tools = {
    ...(videoLayers.length > 0 ? {
      "generate-video": tool({
        description: [
          "Generate a video clip from an existing image layer in this animated sticker.",
          "The layer becomes a looping video in the same position, keeping its artwork as the poster.",
          "Use for explicit video-generation requests or motion requiring new frames, such as a",
          "character turning around, speaking, flapping its wings, or changing expression.",
          "motion describes the subject or camera movement. Select the image layer from the document.",
          "Costs a video generation; takes longer than keyframes. Duration is 2–4 seconds, one clip per sticker.",
          "For simple movement, scaling, flat rotation, or fading, prefer animate-sticker.",
        ].join(" "),
        inputSchema: videoInput,
        execute: async (value) => value,
      }),
    } : {}),
    reply: tool({
      description: [
        "Answer the user in words and change nothing. This is the correct choice whenever the user",
        "is asking a question, chatting, giving feedback, or saying anything that is not a request",
        "to change the sticker — for example 'who is this?', 'what can you do?', 'why did it look",
        "like that?', 'thanks', or 'I like it'.",
        "Generating or editing a sticker destroys the current candidate, so when it is unclear",
        "whether the user wants a change, reply and ask them instead of guessing.",
      ].join(" "),
      inputSchema: z
        .object({ message: z.string().trim().min(1).max(2_000) })
        .strict(),
      execute: async (value) => value,
    }),
    "generate-sticker": tool({
      description: [
        "Generate a new sticker candidate when no existing sticker should be preserved.",
        "Set usePlanImage when the user explicitly asks to use the previous plan image or static",
        "plan reference as the visual source; that image is one of the labeled project images.",
      ].join(" "),
      inputSchema: z
        .object({
          instruction: z.string().trim().min(1).max(8_000),
          usePlanImage: z.boolean().optional(),
        })
        .strict(),
      execute: async (value) => value,
    }),
    "generate-image": tool({
      description: [
        "Draw one new element as its own image layer on a transparent background and add it to the",
        "current sticker, leaving every existing layer untouched.",
        "This is the only tool that draws new artwork onto an existing sticker, so use it when the",
        "user asks for something to be added alongside what is already there — a hat on the",
        "character, a second creature, a prop, a badge — or when the new element must be its own",
        "layer so it can be moved, scaled, or faded independently later.",
        "It is also the tool for drawing something the sticker currently fakes with a text, shape,",
        "or particle layer — 'make the lettering hand-drawn', 'draw that star properly'.",
        "Prefer generate-sticker when the whole sticker should be redrawn from scratch, and",
        "edit-sticker when artwork that already exists should change.",
        "Set usePlanImage when the user explicitly wants this element styled from the previous",
        "plan image or static plan reference shown among the labeled project images.",
      ].join(" "),
      inputSchema: z
        .object({
          instruction: z.string().trim().min(1).max(8_000),
          usePlanImage: z.boolean().optional(),
        })
        .strict(),
      execute: async (value) => value,
    }),
    "edit-sticker": tool({
      description: [
        "Change the sticker that already exists, from natural-language instructions.",
        "It owns the whole layer stack: it redraws artwork, and it also adds, removes, reorders,",
        "renames, re-letters, restyles, and moves layers of every type — including the text, shape,",
        "and particle layers the app draws itself.",
        "So this is the tool for 'remove the caption', 'make the text smaller', 'put the badge",
        "behind the cat', 'recolour the sparkles', and 'make it blue' alike.",
        "Replace is the default; add means the user wants something new alongside what is there.",
      ].join(" "),
      inputSchema: z
        .object({
          instruction: z.string().trim().min(1).max(8_000),
          imagePlacement: z.enum(["replace", "add"]),
          targetLayerId: z
            .string()
            .min(1)
            .max(64)
            .optional()
            .describe(
              [
                "Id of the layer the user is pointing at. Any layer id in the current document is",
                "valid, whatever its type. Omit this unless they clearly name one.",
              ].join(" "),
            ),
          usePlanImage: z.boolean().optional().describe(
            "Use the latest plan's static reference as an image input when the user explicitly points to it.",
          ),
        })
        .strict(),
      execute: async (value) => value,
    }),
    "animate-sticker": tool({
      description: [
        "Add motion to the current animated sticker by keyframing the layers it already has.",
        "It works on whatever sticker is on screen, including a candidate the user has not kept yet.",
        "It can move, scale, rotate, fade, and apply effects to existing layers.",
        "It cannot create new artwork, so it cannot reveal elements that are not already separate",
        "layers — a word drawn inside one flat image cannot be typed out letter by letter.",
      ].join(" "),
      inputSchema: z
        .object({
          instruction: z.string().trim().min(1).max(8_000),
          targetLayerId: z.string().min(1).max(64).optional(),
        })
        .strict(),
      execute: async (value) => value,
    }),
    "plan-sticker": tool({
      description: [
        "Design a sticker as a set of independent layers before anything is generated: which",
        "layers exist, where each one sits, and how each one moves.",
        "Use this when the sticker needs elements that appear, move, or are positioned",
        "independently — per-letter text effects such as a typewriter reveal, multi-character",
        "scenes, staged reveals, or motion where different parts move at different times.",
        "This only drafts a plan for the user to confirm; it does not generate anything, so it is",
        "the slowest way to change a sticker and the only one that needs their approval.",
        "Prefer edit-sticker for any change to a sticker that already exists — it adds, removes,",
        "re-letters, restyles, and rearranges layers directly, in one turn and without a card to",
        "confirm. Reach for a plan only when the sticker has to be restructured into a new set of",
        "independently moving parts.",
        "Prefer generate-sticker when one unified image would do.",
      ].join(" "),
      inputSchema: z
        .object({ instruction: z.string().trim().min(1).max(8_000) })
        .strict(),
      execute: async (value) => value,
    }),
    "show-sticker": tool({
      description:
        "Show the current sticker inline in chat as an attachment without changing it.",
      inputSchema: z
        .object({ caption: z.string().trim().min(1).max(1_000) })
        .strict(),
      execute: async (value) => value,
    }),
  };
  const result = await generateText({
    model: chatModel ?? gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system: [
      "You are Sticker Factory's tool-routing agent.",
      "Choose exactly one tool from the user's natural-language request; the app has no edit mode, animation mode, or layer picker.",
      // Every other rule here selects between mutations, which on its own reads as "the user always
      // wants a change". Questions are a large share of real turns, so the not-a-change case has to
      // come first and be stated as strongly as the rest.
      "First decide whether the user is asking for a change to the sticker at all.",
      "If they are not — a question about the sticker or about you, a comment, feedback, thanks,",
      "small talk, or anything you are unsure about — call reply. Questions such as 'who is this?',",
      "'what is that?', 'what can you do?', or 'why does it look like that?' are answered with reply,",
      "never by generating or editing.",
      "Only pick generate-sticker, generate-image, generate-video, edit-sticker, animate-sticker, or plan-sticker when",
      "the user is actually asking for the artwork to change. Those tools discard the current candidate,",
      "so a wrong guess loses the user's work; when in doubt, reply and ask what they want.",
      "Use show-sticker when the user asks to see or preview the current sticker without changing it.",
      "Separate the three ways artwork can change. generate-sticker redraws the whole sticker and",
      "keeps nothing. generate-image draws one new element on a transparent background and adds it",
      "as its own layer, leaving the existing layers alone — this is the right tool for 'add a…',",
      "'put a… next to it', or 'give it a…'. edit-sticker changes the sticker that is already there.",
      "edit-sticker owns the whole layer stack, not just the drawn artwork: removing a caption,",
      "rewording or recolouring text, resizing or reordering a layer, and redrawing an image are all",
      "edit-sticker, and any layer id may be passed as targetLayerId whatever its type.",
      "Use animate-sticker only for animated projects. Prefer the user's exact instruction and omit targetLayerId unless they clearly name one of the supplied layer ids.",
      "When a reference image is attached and the user requests a change, use edit-sticker.",
      "The labeled project images are visible and usable even when the latest message has no new",
      "attachment. If one is the previous plan's static reference and the user says to use the",
      "plan image or static reference, this is a change request: choose generate-sticker,",
      "generate-image, or edit-sticker as appropriate and set usePlanImage to true. Do not call",
      "reply to claim the image is unavailable or ask the user to upload it again.",
      "Decide between animate-sticker and plan-sticker by what the requested motion needs.",
      "When generate-video is available, use it for explicit video requests or motion that needs new",
      "frames, such as talking, wing flapping, or turning to another viewing angle. Do not route those",
      "requests to keyframes or planning when an existing image layer can be animated into a clip.",
      "When describing your capabilities, include video generation if generate-video is available.",
      "Video needs an animated project with an image layer and no existing clip; static projects cannot play it.",
      "animate-sticker only re-keyframes the layers listed in the current document, so it can only move,",
      "scale, rotate, or fade artwork that already exists as its own layer.",
      "If the effect needs elements to appear, build up, or move one at a time — a typewriter or",
      "letter-by-letter reveal, a word spelling itself out, characters entering in sequence — and those",
      "elements are not already separate layers in the current document, use plan-sticker instead:",
      "it designs the sticker as one layer per element so each can be animated on its own.",
      "Never promise a per-element effect that animate-sticker cannot produce.",
      "plan-sticker is the last resort for an existing sticker, because it only drafts a design the",
      "user then has to confirm. Restructuring a sticker one layer at a time — removing a layer,",
      "swapping one kind of layer for another, laying them out differently — is edit-sticker, which",
      "does it in place and in one turn. Keep plan-sticker for a sticker that has to be rebuilt as a",
      "new set of independently moving parts, and never reach for generate-sticker to change a",
      "sticker that exists: it throws every layer away and redraws from nothing.",
      // The kind is the project's whole contract with the user: they picked "animated" before they
      // typed a word, and a flat image cannot be keyframed into anything, so a generate on an
      // unplanned animated project silently delivers the static sticker they did not ask for.
      "The sticker kind below is the user's standing choice for this project, not a detail of this turn.",
      "On a static project the sticker never moves: never call animate-sticker or plan-sticker for motion.",
      "On an animated project the finished sticker has to move, and only layers can be keyframed.",
      "So when an animated project has no plan yet, design it with plan-sticker rather than drawing it",
      "with generate-sticker. An existing image layer can still be animated into a clip with generate-video.",
    ].join(" "),
    messages: userTurn([
      `Sticker kind: ${input.stickerKind}`,
      `Planned as layers already: ${input.hasPlan ? "yes" : "no"}`,
      priorArtNote(priorArt),
      `Attached reference images: ${input.attachmentCount}`,
      attachedImagesNote(
        viewable.length,
        "Route on what they actually are: a photo of a person or a pet is a subject to build the"
        + " sticker from, a screenshot of a sticker is a style to match, and a picture attached to"
        + " a question is usually still a question.",
      ),
      input.document
        ? `Current StickerDocument: ${JSON.stringify(input.document)}`
        : "There is no current sticker document.",
      `Recoverable chat history:\n${input.history}`,
      `Latest user message:\n${input.instruction}`,
    ].filter(Boolean).join("\n\n"), [...priorArt.map((visual) => visual.image), ...viewable]),
    tools,
    toolChoice: "required",
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(90_000),
  });
  await recordTextApiCost(result);
  if (result.toolCalls.length !== 1)
    throw new Error("Sticker chat agent must return exactly one tool call");
  const call = result.toolCalls[0];
  if (!call) throw new Error("Sticker chat agent returned no tool call");
  switch (call.toolName) {
    case "generate-video": {
      if (videoLayers.length === 0) throw new Error("Video generation is unavailable for this sticker");
      const value = videoInput.parse(call.input);
      return { type: "generate_video", instruction: value.motion, layerId: value.layerId, durationSeconds: value.durationSeconds };
    }
    case "reply": {
      const value = z.object({ message: z.string() }).parse(call.input);
      return { type: "reply", message: value.message };
    }
    case "generate-sticker": {
      const value = z.object({ instruction: z.string(), usePlanImage: z.boolean().optional() }).parse(call.input);
      return { type: "generate", instruction: value.instruction, usePlanImage: value.usePlanImage };
    }
    case "generate-image": {
      const value = z.object({ instruction: z.string(), usePlanImage: z.boolean().optional() }).parse(call.input);
      return { type: "generate_image", instruction: value.instruction, usePlanImage: value.usePlanImage };
    }
    case "edit-sticker": {
      const value = z
        .object({
          instruction: z.string(),
          imagePlacement: z.enum(["replace", "add"]),
          targetLayerId: z.string().optional(),
          usePlanImage: z.boolean().optional(),
        })
        .parse(call.input);
      return resolveChatAction(
        {
          type: "edit",
          instruction: value.instruction,
          imagePlacement: value.imagePlacement,
          targetLayerId: value.targetLayerId,
          usePlanImage: value.usePlanImage,
        },
        input.document,
      );
    }
    case "animate-sticker": {
      const value = z
        .object({
          instruction: z.string(),
          targetLayerId: z.string().optional(),
        })
        .parse(call.input);
      return resolveChatAction(
        {
          type: "animate",
          instruction: value.instruction,
          targetLayerId: value.targetLayerId,
        },
        input.document,
      );
    }
    case "plan-sticker": {
      const value = z.object({ instruction: z.string() }).parse(call.input);
      return { type: "plan", instruction: value.instruction };
    }
    case "show-sticker": {
      const value = z.object({ caption: z.string() }).parse(call.input);
      return { type: "show", caption: value.caption };
    }
  }
  throw new Error(`Unsupported sticker chat tool: ${String(call.toolName)}`);
}

export async function showSticker(
  revisionId: string,
  kind: "static" | "animated",
  instruction: string,
  history: string,
): Promise<string> {
  const tools = {
    "show-sticker": tool({
      description:
        "Attach the completed sticker revision to the assistant's next chat message.",
      inputSchema: z
        .object({ caption: z.string().trim().min(1).max(1_000) })
        .strict(),
      execute: async (value) => value,
    }),
  };
  const result = await generateText({
    model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system:
      "A sticker revision is ready. Call show-sticker exactly once with a concise caption that says what changed and invites further natural-language refinement.",
    prompt: `Revision id: ${revisionId}\nSticker kind: ${kind}\nUser request: ${instruction}\nRecoverable chat history:\n${history}`,
    tools,
    toolChoice: { type: "tool", toolName: "show-sticker" },
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(60_000),
  });
  await recordTextApiCost(result);
  if (result.toolCalls.length !== 1)
    throw new Error("Sticker agent must call show-sticker exactly once");
  const call = result.toolCalls[0];
  if (call.toolName !== "show-sticker")
    throw new Error("Sticker agent did not call show-sticker");
  return z.object({ caption: z.string() }).parse(call.input).caption;
}

export async function reply(instruction: string, history: string): Promise<string> {
  const result = await generateText({
    model: gateway(process.env.AI_ORCHESTRATOR_MODEL ?? "openai/gpt-5.6"),
    system:
      "You are Sticker Factory's concise creative assistant. Help refine the user's private sticker project. Never claim an edit was made unless an image or animation revision was actually created.",
    prompt: `Recoverable project transcript:\n${history}\n\nLatest user message:\n${instruction}`,
    maxRetries: 2,
    abortSignal: AbortSignal.timeout(90_000),
  });
  await recordTextApiCost(result);
  return result.text.trim();
}

export async function summarizeStickerTitle(input: AiTitleContext): Promise<string> {
  const result = await generateText({
    // A naming call sits between a finished turn and the client being told the turn finished, so
    // it runs on the cheapest model the deployment has rather than the orchestrator's.
    model: gateway(
      process.env.AI_SUMMARY_MODEL ??
        process.env.AI_ORCHESTRATOR_MODEL ??
        "openai/gpt-5.6",
    ),
    system: [
      "Name a sticker project from its chat transcript. Reply with the name alone:",
      "two to five words, title case, no quotes, no trailing punctuation, at most 48 characters.",
      "Name the sticker — its subject and its mood — not the conversation about it.",
      "If the current name still describes the sticker, repeat it back unchanged.",
    ].join(" "),
    prompt: `Current name: ${input.currentTitle}\nSticker kind: ${input.stickerKind}\nProject transcript:\n${input.history}`,
    // One attempt over again: the turn is already finished and waiting on this, and the caller
    // keeps the old name when it fails.
    maxRetries: 1,
    abortSignal: AbortSignal.timeout(20_000),
  });
  await recordTextApiCost(result);
  return result.text.trim();
}
