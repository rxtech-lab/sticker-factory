import { type LanguageModel } from "ai";
import { animateSticker } from "./gateway-animate";
import { reply, routeChatTurn, showSticker, summarizeStickerTitle } from "./gateway-chat";
import type { AiAnimationContext, AiChatContext, AiEditContext, AiImageInput, AiLayoutContext, AiPlanContext, AiProvider, AiReferenceSelectionContext, AiTitleContext, AiVideoInput, AnimationDraftingSession, EditDraftingSession, LayoutDraftingSession, PlanDraftingSession } from "./gateway-contracts";
import { editSticker } from "./gateway-edit";
import { generateConceptImage, generateStickerImage, generateStickerVideo, selectImageReferences } from "./gateway-images";
import { MockAiProvider } from "./gateway-mock";
import { planSticker, refineStickerLayout } from "./gateway-plan";

export class GatewayAiProvider implements AiProvider {
  constructor(private readonly chatModel?: LanguageModel) {}

  selectImageReferences(input: AiReferenceSelectionContext) { return selectImageReferences(input); }
  generateStickerImage(input: AiImageInput) { return generateStickerImage(input); }
  generateStickerVideo(input: AiVideoInput) { return generateStickerVideo(input); }
  generateConceptImage(input: { prompt: string; references: Array<{ bytes: Uint8Array; mimeType: string }> }) {
    return generateConceptImage(input);
  }
  refineStickerLayout(input: AiLayoutContext, session: LayoutDraftingSession) {
    return refineStickerLayout(input, session);
  }
  animateSticker(input: AiAnimationContext, session: AnimationDraftingSession) {
    return animateSticker(input, session);
  }
  editSticker(input: AiEditContext, session: EditDraftingSession) { return editSticker(input, session); }
  planSticker(input: AiPlanContext, session: PlanDraftingSession) { return planSticker(input, session); }
  routeChatTurn(input: AiChatContext) { return routeChatTurn(input, this.chatModel); }
  showSticker(revisionId: string, kind: "static" | "animated", instruction: string, history: string) {
    return showSticker(revisionId, kind, instruction, history);
  }
  reply(instruction: string, history: string) { return reply(instruction, history); }
  summarizeStickerTitle(input: AiTitleContext) { return summarizeStickerTitle(input); }
}

let testProvider: AiProvider | undefined;
let provider: AiProvider | undefined;

export function setAiProviderForTests(value?: AiProvider): void {
  testProvider = value;
}

export function getAiProvider(): AiProvider {
  if (testProvider) return testProvider;
  if (
    process.env.NODE_ENV === "test" ||
    (process.env.NODE_ENV !== "production" &&
      process.env.STICKER_FACTORY_MOCK_SERVICES === "true")
  ) {
    testProvider = new MockAiProvider();
    return testProvider;
  }
  provider ??= new GatewayAiProvider();
  return provider;
}

// The rest of the provider. Re-exported so every existing `@/lib/ai/gateway`
// import keeps working.
export { TurnAbort, describeToolError, resolveChatAction, summarizeDocument } from "./gateway-contracts";
export type { AiAnimationContext, AiChatAction, AiChatContext, AiEditContext, AiImageInput, AiImageOutput, AiImageReferenceCandidate, AiLayoutContext, AiPlanContext, AiPlanVisual, AiProvider, AiReferenceImage, AiReferenceSelectionContext, AiSequenceAsset, AiTitleContext, AiVideoInput, AiVideoOutput, AnimateTurnResult, AnimationDraftState, AnimationDraftingSession, EditDraftState, EditDraftingSession, EditTurnResult, LayoutDraftState, LayoutDraftingSession, LayoutTurnResult, PlanDraftingSession, PlanTurnResult, RenderableSession, StickerRenderResult } from "./gateway-contracts";
export { animationOperationLayerId, validateEditOperation, validatePlannedAnimationOperation } from "./gateway-edit";
