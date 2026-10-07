import { type LanguageModel } from "ai";
import { animateSticker } from "./gateway-animate";
import { reply, routeChatTurn, showSticker, summarizeStickerTitle } from "./gateway-chat";
import type { AiAnimationContext, AiChatContext, AiEditContext, AiImageInput, AiLayoutContext, AiPetActionsContext, AiPetEncounterContext, AiPetFriendContext, AiPetItemsContext, AiPetEventContext, AiPetHeadlinesContext, AiPetInteractionContext, AiPetMemoryContext, AiPetPhotoContext, AiPetPoseContext, AiPetRoomArtInput, AiPetThemeArtInput, AiPetThemeChoiceContext, AiPetThemeDiscoveryContext, AiPetSharedContentContext, AiPetPersonaContext, AiPetStatusContext, AiPetStickerContext, AiPlanContext, AiProvider, AiReferenceSelectionContext, AiSheetInspectionContext, AiTitleContext, AiVideoInput, AnimationDraftingSession, EditDraftingSession, LayoutDraftingSession, PlanDraftingSession } from "./gateway-contracts";
import { editSticker } from "./gateway-edit";
import { generateConceptImage, generatePetRoomArt, generatePetThemeArt, generateStickerImage, generateStickerVideo, inspectSpriteSheet, selectImageReferences } from "./gateway-images";
import { MockAiProvider } from "./gateway-mock";
import { generatePetItems } from "./gateway-pet-items";
import { choosePetStatus, choosePetTheme, discoverPetThemes, generatePetActions, generatePetEncounter, meetPetFriend, generatePetPersona, generatePetRooms, narratePetEvent, noticePetSticker, reactToPetPhoto, reactToPetSharedContent, respondToPetInteraction, searchPetHeadlines } from "./gateway-pet";
import { embedPetMemories, updatePetMemory } from "./gateway-pet-memory";
import { decidePetPose } from "./gateway-pet-pose";
import { planSticker, refineStickerLayout } from "./gateway-plan";

export class GatewayAiProvider implements AiProvider {
  constructor(private readonly chatModel?: LanguageModel) {}

  selectImageReferences(input: AiReferenceSelectionContext) { return selectImageReferences(input); }
  generateStickerImage(input: AiImageInput) { return generateStickerImage(input); }
  inspectSpriteSheet(input: AiSheetInspectionContext) { return inspectSpriteSheet(input); }
  generateStickerVideo(input: AiVideoInput) { return generateStickerVideo(input); }
  generateConceptImage(input: { purpose?: "animation-summary" | "extension"; prompt: string; references: Array<{ bytes: Uint8Array; mimeType: string }> }) {
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
  choosePetStatus(input: AiPetStatusContext) { return choosePetStatus(input); }
  generatePetActions(input: AiPetActionsContext) { return generatePetActions(input); }
  generatePetItems(input: AiPetItemsContext) { return generatePetItems(input); }
  generatePetRooms(input: AiPetActionsContext) { return generatePetRooms(input); }
  generatePetRoomArt(input: AiPetRoomArtInput) { return generatePetRoomArt(input); }
  discoverPetThemes(input: AiPetThemeDiscoveryContext) { return discoverPetThemes(input); }
  choosePetTheme(input: AiPetThemeChoiceContext) { return choosePetTheme(input); }
  generatePetThemeArt(input: AiPetThemeArtInput) { return generatePetThemeArt(input); }
  respondToPetInteraction(input: AiPetInteractionContext) { return respondToPetInteraction(input); }
  reactToPetPhoto(input: AiPetPhotoContext) { return reactToPetPhoto(input); }
  reactToPetSharedContent(input: AiPetSharedContentContext) { return reactToPetSharedContent(input); }
  decidePetPose(input: AiPetPoseContext) { return decidePetPose(input); }
  generatePetPersona(input: AiPetPersonaContext) { return generatePetPersona(input); }
  searchPetHeadlines(input: AiPetHeadlinesContext) { return searchPetHeadlines(input); }
  narratePetEvent(input: AiPetEventContext) { return narratePetEvent(input); }
  generatePetEncounter(input: AiPetEncounterContext) { return generatePetEncounter(input); }
  meetPetFriend(input: AiPetFriendContext) { return meetPetFriend(input); }
  noticePetSticker(input: AiPetStickerContext) { return noticePetSticker(input); }
  embedPetMemories(values: string[]) { return embedPetMemories(values); }
  updatePetMemory(input: AiPetMemoryContext) { return updatePetMemory(input); }
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
export type { AiAnimationContext, AiChatAction, AiChatContext, AiEditContext, AiImageInput, AiImageOutput, AiImageReferenceCandidate, AiLayoutContext, AiPetStatus, AiPetStatusContext, AiPlanContext, AiPlanVisual, AiProvider, AiReferenceImage, AiReferenceSelectionContext, AiSequenceAsset, AiSheetInspection, AiSheetInspectionContext, AiTitleContext, AiVideoInput, AiVideoOutput, AnimateTurnResult, AnimationDraftState, AnimationDraftingSession, EditDraftState, EditDraftingSession, EditTurnResult, LayoutDraftState, LayoutDraftingSession, LayoutTurnResult, PlanDraftingSession, PlanTurnResult, RenderableSession, StickerRenderResult } from "./gateway-contracts";
export { animationOperationLayerId, validateEditOperation, validatePlannedAnimationOperation } from "./gateway-edit";
