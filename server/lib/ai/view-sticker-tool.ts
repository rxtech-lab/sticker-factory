import { tool } from "ai";
import { z } from "zod";
import type { RenderableSession, StickerRenderResult } from "@/lib/ai/gateway";

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
export function viewStickerTool(session: RenderableSession, options: { animated: boolean }) {
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
    // No inputs: it renders the working document, and letting the model pass a time or a layer id
    // would only invite it to ask for a frame that does not exist.
    inputSchema: z.object({}).strict(),
    execute: async (_input, { toolCallId }) => {
      const render = await session.renderSticker();
      renders.set(toolCallId, render);
      return {
        rendered: true,
        frames: render.times.length,
        timesSeconds: render.times.map((time) => Number(time.toFixed(2))),
      };
    },
    toModelOutput: ({ toolCallId, output }) => {
      const render = renders.get(toolCallId);
      renders.delete(toolCallId);
      const summary = render && render.times.length > 1
        ? `Frames at ${output.timesSeconds.map((t) => `${t}s`).join(", ")}, read left to right, top to bottom.`
        : "The sticker as it currently stands.";
      return {
        type: "content",
        value: [
          { type: "text", text: summary },
          ...(render
            ? [{
              type: "file" as const,
              mediaType: "image/png",
              data: { type: "data" as const, data: render.png },
            }]
            : []),
        ],
      };
    },
  });
}
