import {
  pruneMessages,
  type ModelMessage,
  type PrepareStepFunction,
  type ToolSet,
} from "ai";
import { traceEvent } from "@/lib/observability/trace";

/**
 * Context compaction for the chat's two long-lived contexts.
 *
 * A chat turn carries history in two shapes, and both grow without a ceiling:
 *
 *   - the *transcript*, the chat rows the turn is prompted with, which grows one turn at a time and
 *     lives in the database, and
 *   - the *tool loop*, the message list `generateText` accumulates inside a single turn, where every
 *     step appends a tool call, its arguments, and its result — for the plan loop that is a whole
 *     `PlanV1` per revision, and for the edit loop a layer-by-layer document summary per call.
 *
 * Both used to be handled by dropping whatever did not fit. `compactTranscript` and
 * `compactingPrepareStep` below shrink what is there instead, on the same principle in both cases:
 * the newest messages stay verbatim, older ones are reduced rather than deleted, and the record of
 * *what the agent did* — the tool calls — is the last thing to go, because a loop that has forgotten
 * the four redraws it already paid for will happily pay for them again.
 */

/**
 * What one attached image costs a vision model, near enough.
 *
 * Images are downscaled to a single 1024px tile before they are attached (`downscaleForModelInput`),
 * which is around a thousand tokens on every provider that publishes the arithmetic. The exact
 * number matters much less than not counting the pixels as if they were prose — see below.
 */
const IMAGE_PART_TOKENS = 1_500;

/**
 * Rough token count for a message list.
 *
 * Four characters per token of serialized JSON, the estimate the AI SDK's own compaction guide uses.
 * It is only ever compared against a threshold that exists to stop the context running away, so a
 * real tokenizer would buy accuracy nothing here spends.
 *
 * Binary parts are the exception, and they are counted rather than serialized. A `Uint8Array`
 * stringifies as `{"0":137,"1":80,…}` — roughly eight characters per byte — so one attached photo
 * would read as hundreds of thousands of tokens and put every loop that carries an image over the
 * compaction threshold from its first step, pruning tool calls to make room for pixels the estimate
 * never measured correctly in the first place.
 */
export function estimateTokens(messages: ModelMessage[]): number {
  let images = 0;
  const serialized = JSON.stringify(messages, (_key, value) => {
    if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) {
      images += 1;
      return "<image>";
    }
    return value;
  });
  return serialized.length / 4 + images * IMAGE_PART_TOKENS;
}

/**
 * When a tool loop starts compacting, in estimated tokens.
 *
 * Env-overridable so a deployment on a smaller-context model can dial it down without a deploy.
 */
const COMPACT_AFTER_TOKENS = (() => {
  const configured = Number(process.env.AI_COMPACT_AFTER_TOKENS);
  return Number.isFinite(configured) && configured > 0 ? configured : 100_000;
})();

/**
 * How many trailing messages keep their tool calls when a loop is compacted.
 *
 * Deliberately far wider than the three the SDK guide's example keeps. Our loops are not a chat that
 * happens to call tools — the tool calls *are* the work, and each one is a step whose result the next
 * step is supposed to read: `update_animation` restates the operations that were rejected,
 * `edit_image_layer` records that a layer has already been redrawn and paid for, `create_plan` holds
 * the draft every later revision is a change to. Pruning those to a three-message window is how a
 * loop ends up redrawing artwork it already bought or re-sending a plan a tool already refused. A
 * step budget of 10-12 means this window covers most turns outright, and compaction only really
 * bites on the long ones.
 */
const TOOL_CALL_RETENTION_MESSAGES = 12;

export interface CompactionOptions {
  /** Names the loop in the trace line, so a compacted turn can be told apart in the logs. */
  loop: string;
  /** Overrides the token threshold. Defaults to `AI_COMPACT_AFTER_TOKENS`. */
  compactAfterTokens?: number;
  /** Overrides how many trailing messages keep their tool calls. */
  toolCallRetentionMessages?: number;
}

/**
 * A `prepareStep` that compacts the loop's own messages once they get long.
 *
 * `prepareStep` runs before every step with the loop's current message list, and a `messages`
 * override it returns is what later steps append to — so this both shrinks the request about to be
 * sent and keeps it shrunk, rather than re-expanding on the next step.
 *
 * What goes first is reasoning, which is bulky, provider-internal, and of no use to a later step. Tool
 * calls older than the retention window go next, and only then because a call from eight steps back
 * has already been folded into the document the loop is working on. Nothing removes the user's
 * instruction or the system prompt: those are the first message, not part of the accumulated tail.
 */
export function compactingPrepareStep<TOOLS extends ToolSet>(
  options: CompactionOptions,
): PrepareStepFunction<TOOLS> {
  const threshold = options.compactAfterTokens ?? COMPACT_AFTER_TOKENS;
  const retention =
    options.toolCallRetentionMessages ?? TOOL_CALL_RETENTION_MESSAGES;
  return ({ messages, stepNumber }) => {
    const before = estimateTokens(messages);
    if (before <= threshold) return undefined;
    const compacted = pruneMessages({
      messages,
      reasoning: "all",
      toolCalls: `before-last-${retention}-messages`,
      emptyMessages: "remove",
    });
    // Worth a line of its own: a compacted turn is one where the model can no longer see part of what
    // it did, so it is the first thing to check when a long turn starts repeating itself.
    traceEvent("ai.compaction", {
      loop: options.loop,
      stepNumber,
      messagesBefore: messages.length,
      messagesAfter: compacted.length,
      tokensBefore: Math.round(before),
      tokensAfter: Math.round(estimateTokens(compacted)),
      retention,
    });
    return { messages: compacted };
  };
}

/** The shape `compactTranscript` needs from a chat row, so it can be tested without a database. */
export interface TranscriptMessage {
  role: "user" | "assistant" | "system";
  kind: string;
  content: string;
}

/** Newest messages that stay word for word, as a share of the whole budget. */
const VERBATIM_SHARE = 0.6;

/** Older messages that survive as a digest are clipped to this many characters each. */
const DIGEST_LINE_CHARACTERS = 200;

/**
 * Share of the budget reserved for tool-call rows, which nothing else may spend.
 *
 * A tool-call row is its tool's name and nothing else — around twenty characters — so this holds
 * well over a hundred of them. That is the point: they are the cheapest lines in the transcript and
 * the ones that say what actually happened to the sticker, so they are kept long after the prose
 * around them has been dropped.
 */
const TOOL_USE_SHARE = 0.2;

/** A tool-call row: the machinery of a turn rather than anything a person wrote. */
function isToolUse(message: TranscriptMessage): boolean {
  return message.role === "system" && message.kind === "status";
}

export interface TranscriptOptions {
  /**
   * Keep every message a person or the assistant actually wrote, in full.
   *
   * The digest below is the right trade for a loop that is *changing* something: an edit turn works
   * from the document in front of it, and the wording of a request from nine turns ago adds little.
   * Planning is the opposite. A plan is a design brief, and the brief is spread across the whole
   * conversation — the character the user named in their first message, the style they rejected in
   * their third, the "actually make it a cat" in their sixth. Clipped to two hundred characters
   * apiece those survive as gist, which is precisely the part a re-plan needs verbatim, so under this
   * flag only the tool-call rows are budgeted and the conversation itself is never cut.
   */
  keepChatVerbatim?: boolean;
}

/**
 * Renders a thread with every chat message intact, budgeting only the tool-call rows around them.
 *
 * The one thing here that is bounded is the machinery: tool rows are collected newest-first out of
 * `toolBudget` and counted when they do not fit. The chat itself has no ceiling by design — see
 * `keepChatVerbatim`. That makes the prompt's size a function of how long the user's conversation is,
 * which is a cost worth knowing about: a hundred-turn thread is a hundred turns of prompt.
 */
function verbatimChatTranscript(
  messages: TranscriptMessage[],
  toolBudget: number,
): string {
  const lines: string[] = [];
  let toolUsed = 0;
  let dropped = 0;

  // Backwards, so the tool rows that survive a spent budget are the most recent ones.
  for (const message of [...messages].reverse()) {
    const line = lineFor(message);
    if (!isToolUse(message)) {
      lines.push(line);
      continue;
    }
    if (toolUsed + line.length > toolBudget) {
      dropped += 1;
      continue;
    }
    toolUsed += line.length;
    lines.push(line);
  }

  if (dropped > 0) {
    lines.push(
      `[${dropped} earlier tool-call row${dropped === 1 ? "" : "s"} omitted from this transcript; `
        + "no chat message is missing]",
    );
  }
  return lines.reverse().join("\n");
}

/**
 * Renders one row as prompt text.
 *
 * `device_edit` rows are the reason this is not just `role: content`. They are stored with role
 * `user` and a content string like "Edited on device", so rendered plainly they are indistinguishable
 * from the user having *typed* that sentence — and the one thing they actually mean, that the
 * document changed underneath the agent since its last turn, is exactly what is lost. An agent that
 * misses it goes on to build operations against the document it remembers producing and quietly
 * reverts whatever the user just did by hand.
 */
function lineFor(message: TranscriptMessage): string {
  if (message.kind === "device_edit") {
    return `system: [The user edited the sticker directly in the on-device editor: "${message.content}". `
      + "This did not come from you, and the current sticker document already contains it. "
      + "Read that document as it is now and build on it; do not work from any earlier version.]";
  }
  return `${message.role}: ${message.content}`;
}

/** Shortens a line to at most `characters`, the ellipsis included, so a budget is never overspent. */
function clip(line: string, characters: number): string {
  return line.length <= characters
    ? line
    : `${line.slice(0, characters - 1)}…`;
}

/**
 * Renders a thread as prompt text that fits a character budget, compacting rather than truncating.
 *
 * The previous version walked backwards adding whole lines and stopped at the first one that did not
 * fit, which on a long project meant the model was handed the last few turns and no indication that
 * anything came before them. Three things changed:
 *
 *   - the newest turns still go in verbatim, because a follow-up like "make it smaller" is only
 *     answerable from the exact words around it;
 *   - everything older is clipped to a line apiece instead of dropped, so the shape of the project
 *     survives even when its wording does not; and
 *   - tool-call rows are paid for out of their own reserve and keep being collected after the prose
 *     budget is spent, so the record of what was generated, edited, animated, and planned reaches
 *     the model even on a thread far longer than the budget.
 *
 * Anything that still does not fit is counted, and the count is stated in the output — a model told
 * that eleven messages are missing asks about them, where one that is simply handed a truncated
 * history assumes it has the whole story.
 *
 * `options.keepChatVerbatim` opts out of the digest entirely and keeps every chat message; the plan
 * loop is the one caller that asks for it.
 */
export function compactTranscript(
  messages: TranscriptMessage[],
  maxCharacters = 24_000,
  options: TranscriptOptions = {},
): string {
  const toolBudget = Math.floor(maxCharacters * TOOL_USE_SHARE);
  // Under `keepChatVerbatim` the character budget governs the tool rows alone; the prose is exempt
  // from it rather than measured against it.
  if (options.keepChatVerbatim) return verbatimChatTranscript(messages, toolBudget);
  const verbatimBudget = Math.floor(maxCharacters * VERBATIM_SHARE);
  const lines: string[] = [];
  let verbatimUsed = 0;
  let digestUsed = 0;
  let digestBudget = 0;
  let toolUsed = 0;
  let dropped = 0;
  let digesting = false;

  for (const message of [...messages].reverse()) {
    const line = lineFor(message);
    if (!digesting) {
      // The newest message goes in whatever its size: a budget so small that the turn being answered
      // does not fit is a misconfiguration, and an empty history is worse than an oversized one.
      if (lines.length === 0 || verbatimUsed + line.length <= verbatimBudget) {
        lines.push(clip(line, maxCharacters));
        verbatimUsed += line.length;
        continue;
      }
      digesting = true;
      // Whatever the verbatim pass left unspent goes to the digest rather than being forfeited, so a
      // thread of a few short turns is never compacted at all.
      digestBudget = Math.max(0, maxCharacters - verbatimUsed - toolBudget);
    }

    if (isToolUse(message)) {
      if (toolUsed + line.length > toolBudget) {
        dropped += 1;
        continue;
      }
      toolUsed += line.length;
      lines.push(line);
      continue;
    }

    const digested = clip(line, DIGEST_LINE_CHARACTERS);
    if (digestUsed + digested.length > digestBudget) {
      // Not a `break`: the loop keeps walking back so tool-call rows older than this one can still be
      // collected out of their own reserve.
      dropped += 1;
      continue;
    }
    digestUsed += digested.length;
    lines.push(digested);
  }

  if (dropped > 0) {
    lines.push(
      `[${dropped} earlier message${dropped === 1 ? "" : "s"} omitted from this transcript]`,
    );
  }
  return lines.reverse().join("\n");
}
