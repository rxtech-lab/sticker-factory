import { tool } from "ai";
import { z } from "zod";
import type { AiReferenceImage } from "@/lib/ai/gateway";
import { describeError, traceEvent } from "@/lib/observability/trace";

/**
 * Gives the layout reviewer the approved plan image only when it asks to inspect it.
 *
 * Keeping the pixels behind a tool matters because an image attached to the opening message is sent
 * again on every step of the review loop. The tool result enters the conversation once, immediately
 * before the comparison, while the original full-resolution image stays out of model history.
 */
export function viewPlanImageTool(loadImage: () => Promise<AiReferenceImage>) {
  const images = new Map<string, AiReferenceImage>();

  return tool({
    description: [
      "View the approved plan image that this generated sticker is meant to match.",
      "Call this before judging the generated sticker, then call view_sticker and compare the two:",
      "match the plan's placement, relative sizes, spacing, and intentional overlap. The plan image",
      "is the target composition, not general inspiration. It is a still frame, so ignore differences",
      "that are only animation timing, and do not try to repair details inside a layer's own artwork.",
      "This only views the saved plan image; it does not generate or change anything.",
    ].join(" "),
    inputSchema: z.object({}).strict(),
    execute: async (_input, { toolCallId }) => {
      const startedAt = Date.now();
      try {
        const image = await loadImage();
        images.set(toolCallId, image);
        traceEvent("view_plan_image:ok", {
          toolCallId,
          ms: Date.now() - startedAt,
          imageBytes: image.bytes.byteLength,
        });
        return { viewed: true };
      } catch (error) {
        traceEvent("view_plan_image:fail", {
          toolCallId,
          ms: Date.now() - startedAt,
          error: describeError(error),
        });
        throw error;
      }
    },
    toModelOutput: ({ toolCallId }) => {
      const image = images.get(toolCallId);
      images.delete(toolCallId);
      if (!image) traceEvent("view_plan_image:no-image", { toolCallId });
      return {
        type: "content",
        value: [
          { type: "text", text: "The approved plan image to compare with the generated sticker." },
          ...(image
            ? [{
              type: "file" as const,
              mediaType: image.mimeType,
              data: { type: "data" as const, data: image.bytes },
            }]
            : []),
        ],
      };
    },
  });
}
