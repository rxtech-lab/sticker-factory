import type { ModelMessage } from "ai";
import { describe, expect, it } from "vitest";
import {
  compactingPrepareStep,
  compactTranscript,
  estimateTokens,
  type TranscriptMessage,
} from "@/lib/ai/compaction";

function userMessage(content: string): TranscriptMessage {
  return { role: "user", kind: "text", content };
}

function assistantMessage(content: string): TranscriptMessage {
  return { role: "assistant", kind: "image", content };
}

function toolUse(toolName: string): TranscriptMessage {
  return { role: "system", kind: "status", content: toolName };
}

/** Stored with role `user`, because the editor saves it on the user's behalf. */
function deviceEdit(note: string): TranscriptMessage {
  return { role: "user", kind: "device_edit", content: note };
}

describe("device edit markers", () => {
  it("renders a device edit as a system note rather than as something the user typed", () => {
    const rendered = compactTranscript([deviceEdit("Nudged the dot")]);
    // The failure this guards against is subtle and expensive: rendered as `user: Nudged the dot`
    // it reads as a request to nudge a dot, and the agent nudges it a second time.
    expect(rendered).not.toBe("user: Nudged the dot");
    expect(rendered.startsWith("system: [")).toBe(true);
    expect(rendered).toContain("Nudged the dot");
    expect(rendered).toContain("on-device editor");
    // The instruction that makes the marker actionable at all.
    expect(rendered).toMatch(/current sticker document already contains it/i);
  });

  it("leaves ordinary user turns alone", () => {
    expect(compactTranscript([userMessage("Nudged the dot")])).toBe("user: Nudged the dot");
  });

  it("still marks a device edit once it has aged into the digest", () => {
    const rendered = compactTranscript([
      deviceEdit("Moved the star"),
      userMessage("z".repeat(4_000)),
      userMessage("now make it spin"),
    ], 2_000);
    expect(rendered).toContain("on-device editor");
  });
});

describe("compactTranscript", () => {
  it("passes a short thread through untouched", () => {
    const transcript = [
      userMessage("a cat wearing a hat"),
      toolUse("generate-sticker"),
      assistantMessage("Here is your cat."),
    ];
    expect(compactTranscript(transcript)).toBe(
      ["user: a cat wearing a hat", "system: generate-sticker", "assistant: Here is your cat."].join("\n"),
    );
  });

  it("keeps the newest turn verbatim and digests the older ones", () => {
    const transcript = [
      userMessage("x".repeat(4_000)),
      userMessage("y".repeat(4_000)),
      userMessage("make it smaller"),
    ];
    const compacted = compactTranscript(transcript, 2_000);
    const lines = compacted.split("\n");
    expect(lines.at(-1)).toBe("user: make it smaller");
    // The older two survive as clipped digests rather than being dropped outright.
    expect(lines.filter((line) => line.endsWith("…"))).toHaveLength(2);
    expect(compacted).not.toContain("x".repeat(4_000));
  });

  it("keeps tool-use rows long after the prose budget is spent", () => {
    const transcript: TranscriptMessage[] = [];
    for (let index = 0; index < 40; index += 1) {
      transcript.push(userMessage(`turn ${index} ${"z".repeat(500)}`));
      transcript.push(toolUse(`edit-sticker-${index}`));
    }
    transcript.push(userMessage("and now make it blue"));
    const compacted = compactTranscript(transcript, 8_000);
    const toolLines = compacted
      .split("\n")
      .filter((line) => line.startsWith("system: edit-sticker-"));
    // Every tool-call row fits in its own reserve even though most of the prose around them did not.
    expect(toolLines).toHaveLength(40);
    expect(toolLines[0]).toBe("system: edit-sticker-0");
    expect(compacted).toContain("earlier messages omitted");
    expect(compacted.length).toBeLessThanOrEqual(8_500);
  });

  it("keeps the newest message even when it alone exceeds the budget", () => {
    const compacted = compactTranscript([userMessage("q".repeat(5_000))], 1_000);
    expect(compacted).toHaveLength(1_000);
  });

  it("counts what it had to drop", () => {
    const transcript = Array.from({ length: 30 }, (_, index) =>
      userMessage(`${index}: ${"w".repeat(400)}`),
    );
    const compacted = compactTranscript(transcript, 1_200);
    expect(compacted).toMatch(/\[\d+ earlier messages omitted from this transcript\]/);
  });
});

describe("estimateTokens", () => {
  const withImage = (bytes: number): ModelMessage[] => [
    {
      role: "user",
      content: [
        { type: "text", text: "make this a sticker" },
        { type: "image", image: new Uint8Array(bytes).fill(137), mediaType: "image/jpeg" },
      ],
    },
  ];

  it("counts an attached image as a picture rather than as its bytes", () => {
    // A `Uint8Array` serializes as `{"0":137,"1":137,…}` — around eight characters a byte — so
    // without special handling a 60 KB photo alone reads as more than a hundred thousand tokens
    // and every loop carrying one starts compacting on its first step.
    expect(estimateTokens(withImage(60_000))).toBeLessThan(10_000);
  });

  it("does not charge more for a larger image", () => {
    // The provider tiles whatever it is given, so the file size is not what the model is billed for.
    expect(estimateTokens(withImage(200_000))).toBe(estimateTokens(withImage(20_000)));
  });

  it("still counts the words around it", () => {
    const wordy: ModelMessage[] = [
      {
        role: "user",
        content: [
          { type: "text", text: "x".repeat(40_000) },
          { type: "image", image: new Uint8Array(1_000).fill(137), mediaType: "image/jpeg" },
        ],
      },
    ];
    expect(estimateTokens(wordy)).toBeGreaterThan(estimateTokens(withImage(1_000)) + 9_000);
  });
});

describe("compactingPrepareStep", () => {
  const bulkyToolCall = (index: number): ModelMessage[] => [
    {
      role: "assistant",
      content: [
        {
          type: "tool-call",
          toolCallId: `call-${index}`,
          toolName: "update_plan",
          input: { plan: { filler: "p".repeat(4_000) } },
        },
      ],
    },
    {
      role: "tool",
      content: [
        {
          type: "tool-result",
          toolCallId: `call-${index}`,
          toolName: "update_plan",
          output: { type: "json", value: { revision: index } },
        },
      ],
    },
  ];

  const step = (messages: ModelMessage[]) =>
    (compactingPrepareStep({ loop: "test", compactAfterTokens: 2_000 }) as (options: {
      messages: ModelMessage[];
      stepNumber: number;
    }) => { messages?: ModelMessage[] } | undefined)({ messages, stepNumber: messages.length });

  it("leaves a short loop alone", () => {
    const messages: ModelMessage[] = [{ role: "user", content: "draw a cat" }];
    expect(step(messages)).toBeUndefined();
  });

  it("prunes tool calls once the loop outgrows the threshold", () => {
    const messages: ModelMessage[] = [
      { role: "user", content: "draw a cat" },
      ...Array.from({ length: 12 }, (_, index) => bulkyToolCall(index)).flat(),
    ];
    const result = step(messages);
    expect(result?.messages).toBeDefined();
    expect(estimateTokens(result!.messages!)).toBeLessThan(estimateTokens(messages));
    // The user's instruction is never part of the accumulated tail, so it always survives.
    expect(result!.messages![0]).toEqual({ role: "user", content: "draw a cat" });
  });

  it("keeps the most recent tool calls rather than a three-message window", () => {
    const messages: ModelMessage[] = [
      { role: "user", content: "draw a cat" },
      ...Array.from({ length: 12 }, (_, index) => bulkyToolCall(index)).flat(),
    ];
    const serialized = JSON.stringify(step(messages)!.messages);
    // 12 messages of retention covers the last six call/result pairs.
    for (const index of [6, 7, 8, 9, 10, 11]) {
      expect(serialized).toContain(`call-${index}`);
    }
    expect(serialized).not.toContain("call-0");
  });
});
