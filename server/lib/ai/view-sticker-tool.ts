import { tool } from "ai";
import { z } from "zod";
import type { RenderableSession, StickerRenderResult } from "@/lib/ai/gateway";
import { describeError, traceEvent } from "@/lib/observability/trace";

/**
 * The tool that lets a loop look at its own work.
 *
 * Shared by the animate and edit loops because the reason for it is the same in both: every export
 * is rendered on the iOS client, so the server has never had pixels, and a model asked to refine a
 * sticker was reasoning purely about the JSON it had just written. It could not tell that a layer
 * had ended up behind another, that an entrance finished after the sticker did, or that two colours
 * it chose separately fight.
 *
 * Two things about the implementation are load bearing:
 *
 *  1. **The bytes never go through `execute`'s return value.** `prepareStep` compaction estimates
 *     tokens by `JSON.stringify`-ing the message list (`lib/ai/compaction`), and a `Uint8Array`
 *     stringifies as `{"0":137,"1":80,…}` — several times worse than the base64 the provider would
 *     have sent. So the render is parked in a map keyed by `toolCallId` and only `toModelOutput`
 *     pulls it out, which is the hook the SDK calls when it builds the actual tool-result part.
 *  2. **`toModelOutput` returns a `file` part, not the deprecated `image-data` one.** `ai@7` routes
 *     `{type:'content'}` results through the gateway provider, which base64-encodes a `Uint8Array`
 *     for us; `image-data` is deprecated in this version and `media` belongs to the older V2 spec.
 */
export function viewStickerTool(session: RenderableSession, options: { animated: boolean; configurable?: boolean }) {
  // Keyed by tool call so two renders in one turn cannot be confused for each other. Entries are
  // dropped as soon as they are read: the message history holds the bytes from then on, and keeping
  // a second copy alive for the length of a turn is pure memory.
  const renders = new Map<string, StickerRenderResult>();

  return tool({
    description: [
      "Look at the sticker as it currently stands. Returns an image, so this is the only way to",
      "actually see your own work rather than reading it back as numbers.",
      options.animated
        ? "For an animated sticker it returns a contact sheet: several frames sampled across the"
        + " cycle, each captioned with its timestamp, left to right and top to bottom."
        : "For a static sticker it returns a single frame.",
      "For configurable edits, pass controlValues to inspect a selection, or omit them (or send {}) to inspect the next pending state.",
      "The result lists pendingReviewSelections. Review these until the list is empty before finalizing.",
      "Call it after a change you are unsure about and before finalizing, and act on what you see:",
      "a layer drifting off-canvas, two layers overlapping, an entrance that has not started by the",
      "frame it should have, artwork that is invisible because something covers it, colours that",
      "clash. Then fix it with the editing tools and look again.",
      "It costs nothing and generates no artwork, so it is always safe to call.",
      "",
      "Read it as a review render, not as the final export. It is drawn by the server rather than by",
      "the app that ships the sticker, so shape curves, font metrics, particle placement and the",
      "exact look of shine are approximations. Judge layout, timing, coverage and colour from it;",
      "do not judge kerning or a few pixels of curvature, and never redraw artwork solely because",
      "an edge looks slightly different here.",
    ].join(" "),
    inputSchema: z.object({ controlValues: z.record(z.string(), z.union([z.string(), z.number(), z.boolean()])).optional() }).strict(),
    execute: async (_input, { toolCallId }) => {
      const startedAt = Date.now();
      try {
        const render = await session.renderSticker(_input.controlValues);
        renders.set(toolCallId, render);
        traceEvent("view_sticker:ok", {
          toolCallId,
          ms: Date.now() - startedAt,
          frames: render.times.length,
          controlValues: render.controlValues,
          pendingReviewStates: render.pendingReviewSelections?.length,
          sheetBytes: render.bytes.byteLength,
          mimeType: render.mimeType,
        });
        return {
          rendered: true,
          controlValues: render.controlValues,
          pendingReviewSelections: render.pendingReviewSelections,
          frames: render.times.length,
          timesSeconds: render.times.map((time) => Number(time.toFixed(2))),
        };
      } catch (error) {
        // The SDK turns this throw into a tool-error part and the loop carries on, so without a
        // line here the only trace of the failure is the model's own reaction to it, several
        // messages later. `renderSticker` logs the cause; this records that the *tool* is what
        // broke, and which call it was.
        traceEvent("view_sticker:fail", {
          toolCallId,
          ms: Date.now() - startedAt,
          error: describeError(error),
        });
        throw error;
      }
    },
    toModelOutput: ({ toolCallId, output }) => {
      const render = renders.get(toolCallId);
      renders.delete(toolCallId);
      if (!render) {
        // The silent failure this catches: `execute` succeeded, so the model is told a render
        // exists, but the parked bytes are gone and the tool result carries text only. The model
        // then "reviews" a sticker it was never shown and reports back with total confidence.
        traceEvent("view_sticker:no-render", { toolCallId, frames: output.frames });
      }
      const summary = render && render.times.length > 1
        ? `Frames at ${output.timesSeconds.map((t) => `${t}s`).join(", ")}, read left to right, top to bottom.`
        : "The sticker as it currently stands.";
      return {
        type: "content",
        value: [
          { type: "text", text: summary
            + (output.controlValues ? ` Controls: ${JSON.stringify(output.controlValues)}` : "")
            + (output.pendingReviewSelections ? ` Remaining pendingReviewSelections: ${JSON.stringify(output.pendingReviewSelections)}.`
              + (output.pendingReviewSelections.length ? " Call view_sticker with {} to review the next state." : " All required control states have been reviewed.") : "") },
          ...(render
            ? [{
              type: "file" as const,
              // Taken from the render rather than hard-coded: the sheet is WebP, and a `data:` part
              // labelled `image/png` that is not one is rejected by the provider, not corrected.
              mediaType: render.mimeType,
              data: { type: "data" as const, data: render.bytes },
            }]
            : []),
        ],
      };
    },
  });
}
