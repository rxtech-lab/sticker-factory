// The provider used by tests and by local runs with `STICKER_FACTORY_MOCK_SERVICES=true`.

import { readFile } from "node:fs/promises";
import path from "node:path";
import { POSE_COUNTS } from "@/lib/contracts/pose-preset";
import sharp from "sharp";
import { configurationReviewSelections } from "@/lib/contracts/configuration";
import { PlanV1Schema, reusableAssetIds, type PlanV1 } from "@/lib/contracts/plan";
import { type StickerOperationV1 } from "@/lib/contracts/sticker";
import { normalizeTransparentPng } from "@/lib/storage/r2";
import { PET_MEMORY_DIMENSIONS } from "@/lib/contracts/api";
import { GatewayAiProvider } from "./gateway";
import { resolveChatAction } from "./gateway-contracts";
import type { AiAnimationContext, AiChatAction, AiChatContext, AiEditContext, AiImageInput, AiImageOutput, AiLayoutContext, AiPetActionsContext, AiPetEncounter, AiPetItem, AiPetItemsContext, AiPetEncounterContext, AiPetEventContext, AiPetFriend, AiPetFriendContext, AiPetInteractionContext, AiPetMemoryContext, AiPetMemoryOperation, AiPetPhotoContext, AiPetPose, AiPetPoseContext, AiPetRoom, AiPetRoomArtInput, AiPetSharedContentContext, AiPetTheme, AiPetThemeArtInput, AiPetThemeChoice, AiPetThemeChoiceContext, AiPetThemeDiscoveryContext, AiPetPersona, AiPetPersonaContext, AiPetStatus, AiPetStatusContext, AiPetStickerContext, AiPetStickerReaction, AiPlanContext, AiProvider, AiReferenceSelectionContext, AiSheetInspection, AiSheetInspectionContext, AiTitleContext, AiVideoOutput, AnimateTurnResult, AnimationDraftingSession, EditDraftingSession, EditTurnResult, LayoutDraftingSession, LayoutTurnResult, PetAction, PlanDraftingSession, PlanTurnResult } from "./gateway-contracts";

/**
 * What the mock draws for a sprite sheet: one pink body per cell with a magenta face placeholder,
 * nudged a little per cell so a clip has visible motion, or one face plate per cell with a
 * different mouth so expressions can be told apart. Enough for registration and compositing to run
 * end to end in tests.
 */
function mockSheetSvg(sheet: NonNullable<AiImageInput["sheet"]>): string {
  const cellWidth = Math.floor(1024 / sheet.columns), cellHeight = Math.floor(1024 / sheet.rows);
  const cells = Array.from({ length: sheet.count }, (_, index) => {
    const ox = (index % sheet.columns) * cellWidth, oy = Math.floor(index / sheet.columns) * cellHeight;
    const cx = ox + cellWidth / 2, cy = oy + cellHeight / 2;
    const r = Math.min(cellWidth, cellHeight) * 0.32;
    if (sheet.tiles) {
      const smile = index % 2 === 0 ? `M${cx - r * 0.4} ${cy + r * 0.3} Q${cx} ${cy + r * 0.7} ${cx + r * 0.4} ${cy + r * 0.3}` : `M${cx - r * 0.4} ${cy + r * 0.5} Q${cx} ${cy + r * 0.1} ${cx + r * 0.4} ${cy + r * 0.5}`;
      return `<ellipse cx="${cx}" cy="${cy}" rx="${r}" ry="${r * 0.85}" fill="#ffd6a5" stroke="#231f20" stroke-width="6"/>`
        + `<circle cx="${cx - r * 0.35}" cy="${cy - r * 0.2}" r="${r * 0.12}" fill="#231f20"/><circle cx="${cx + r * 0.35}" cy="${cy - r * 0.2}" r="${r * 0.12}" fill="#231f20"/>`
        + `<path d="${smile}" fill="none" stroke="#231f20" stroke-width="8" stroke-linecap="round"/>`;
    }
    const lift = (index % 3) * 6;
    return `<circle cx="${cx}" cy="${cy + r * 0.4 - lift}" r="${r}" fill="#ff8fa3"/>`
      + `<circle cx="${cx}" cy="${cy - r * 0.6 - lift}" r="${r * 0.8}" fill="#ff8fa3"/>`
      + (sheet.facePlaceholder ? `<ellipse cx="${cx}" cy="${cy - r * 0.55 - lift}" rx="${r * 0.55}" ry="${r * 0.45}" fill="#ff00ff"/>` : "");
  }).join("");
  return `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg">${cells}</svg>`;
}

export class MockAiProvider implements AiProvider {
  async selectImageReferences(input: AiReferenceSelectionContext): Promise<number[]> {
    const required = input.candidates
      .map((candidate, index) => (candidate.required ? index : -1))
      .filter((index) => index >= 0);
    const optional = input.candidates
      .map((_, index) => index)
      .filter((index) => !required.includes(index));
    return [...required, ...optional].slice(0, input.maxReferences);
  }

  async generateStickerImage(input: AiImageInput): Promise<AiImageOutput> {
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Sticker";
    const bytes = await sharp(
      Buffer.from(input.sheet ? mockSheetSvg(input.sheet) : (
        `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="none"/><circle cx="512" cy="480" r="360" fill="#ff8fa3"/><circle cx="400" cy="430" r="35" fill="#231f20"/><circle cx="624" cy="430" r="35" fill="#231f20"/><path d="M390 570 Q512 670 634 570" fill="none" stroke="#231f20" stroke-width="28" stroke-linecap="round"/><text x="512" y="900" text-anchor="middle" font-family="system-ui" font-size="68" fill="#231f20">${label}</text></svg>`
      )),
    )
      .png()
      .toBuffer();
    const normalized = await normalizeTransparentPng(bytes, {
      subjectCrop: !input.mask && !input.keepFrame,
      pixelArt: input.pixelArt,
    });
    return { bytes: normalized.bytes, mimeType: "image/png", subject: normalized.subject };
  }

  async refineStickerLayout(
    input: AiLayoutContext,
    session: LayoutDraftingSession,
  ): Promise<LayoutTurnResult | undefined> {
    // Exercise the same mandatory look-before-finalize contract without making tests invent visual
    // judgements. Focused tests cover corrections through the layout session itself.
    if (session.viewPlanImage) await session.viewPlanImage();
    const states = input.document.configuration ? configurationReviewSelections(input.document.configuration) : [{}];
    // One render per choice combination, in order, because the real loop's cursor counts them.
    for (let index = 0; index < states.length; index += 1) await session.renderSticker();
    const finalized = await session.finalizeLayout();
    return { revision: finalized.revision, finalized: true };
  }
  /**
   * Scripts the same create -> update -> finalize shape the real loop produces, so the integration
   * tests exercise the session callbacks and the transcript rows they write.
   *
   * The update restates the scale operations alongside the new rotation ones, because an update is
   * applied to the base document: sending rotation alone would drop the scale motion the create
   * landed, which is exactly the mistake the tool description warns the real model about.
   */
  async animateSticker(
    input: AiAnimationContext,
    session: AnimationDraftingSession,
  ): Promise<AnimateTurnResult | undefined> {
    // Key off the document's real layers so composed documents (part_0, part_1, …) are animated the
    // same way a single-layer `hero` document is, and honour the target so a multi-layer document
    // asked to animate one layer does not trip the session's own targeting guard.
    const layers = input.targetLayerId
      ? input.document.layers.filter(
          (layer) => layer.id === input.targetLayerId,
        )
      : input.document.layers;
    const scale = layers.map(
      (layer): StickerOperationV1 => ({
        op: "setScaleKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, x: 0.9, y: 0.9, easing: "easeOut" },
          { timeSeconds: 1, x: 1.08, y: 1.08, easing: "springSoft" },
          { timeSeconds: 2, x: 0.9, y: 0.9, easing: "easeIn" },
        ],
      }),
    );
    const rotation = layers.map(
      (layer): StickerOperationV1 => ({
        op: "setRotationKeyframes",
        layerId: layer.id,
        keyframes: [
          { timeSeconds: 0, degrees: -5, easing: "easeOut" },
          { timeSeconds: 1, degrees: 5, easing: "easeInOut" },
          { timeSeconds: 2, degrees: -5, easing: "easeIn" },
        ],
      }),
    );

    const created = await session.createAnimation(scale);
    const updated = await session.updateAnimation(created.animationId, [
      ...scale,
      ...rotation,
    ]);
    // One layer given a bigger swell than the rest, sent on its own. The restated scale and rotation
    // above are not repeated: every other layer keeps the motion the update landed, which is the
    // whole of what this tool is for.
    const edited = await session.editLayerAnimation(updated.animationId, layers[0].id, [
      {
        op: "setScaleKeyframes",
        layerId: layers[0].id,
        keyframes: [
          { timeSeconds: 0, x: 0.9, y: 0.9, easing: "easeOut" },
          { timeSeconds: 1, x: 1.2, y: 1.2, easing: "springBouncy" },
          { timeSeconds: 2, x: 0.9, y: 0.9, easing: "easeIn" },
        ],
      },
      rotation[0],
    ]);
    const finalized = await session.finalizeAnimation(edited.animationId);
    return {
      animationId: finalized.animationId,
      revision: finalized.revision,
      finalized: true,
    };
  }
  /**
   * Scripts one landed change followed by a finalize, so the integration tests exercise the session
   * callbacks and the transcript rows they write.
   *
   * Which change it makes is keyed off the request the same way the real model is asked to read it:
   * the free operation when the words ask for a removal, a clip when the words ask for motion no
   * keyframe can express, new artwork when the router said `add` or when there is no artwork to
   * work from, and otherwise a redraw of the targeted image layer — which is the whole of what the
   * edit turn could do before it became a loop.
   */
  async editSticker(
    input: AiEditContext,
    session: EditDraftingSession,
  ): Promise<EditTurnResult | undefined> {
    const normalized = input.instruction.toLowerCase();
    const named = input.targetLayerId
      ? input.document.layers.find((layer) => layer.id === input.targetLayerId)
      : undefined;
    const appDrawn = named && named.type !== "image"
      ? named
      : input.document.layers.find((layer) => layer.type !== "image");
    const artwork = named?.type === "image"
      ? named
      : input.document.layers.find((layer) => layer.type === "image");

    if (/\b(remove|delete|drop)\b/.test(normalized) && appDrawn) {
      await session.applyOperations([{ op: "removeLayer", layerId: appDrawn.id }]);
    // Read off the words the way the real loop's prompt tells it to: a request for an angle change
    // is the one thing keyframes cannot serve, so it is the one that buys a clip.
    } else if (artwork && input.document.kind === "animated" && /\b(turnaround|turntable|spin all the way|clip|video)\b/.test(normalized)) {
      await session.createVideoLayer({
        layerId: artwork.id,
        motion: input.instruction,
        durationSeconds: 2,
      });
    } else if (input.imagePlacement === "add" || !artwork) {
      await session.addImageLayer({ prompt: input.instruction, name: "Generated layer" });
      // Artwork standing in for an app-drawn layer the user named: the layer it replaces goes too.
      if (!artwork && named && named.type !== "image") {
        await session.applyOperations([{ op: "removeLayer", layerId: named.id }]);
      }
    } else {
      await session.editImageLayer({ layerId: artwork.id, prompt: input.instruction });
    }

    const finalized = await session.finalizeEdit();
    return { revision: finalized.revision, finalized: true };
  }

  async generateConceptImage(input: {
    purpose?: "animation-summary" | "extension";
    prompt: string;
    references: Array<{ bytes: Uint8Array; mimeType: string }>;
  }): Promise<AiImageOutput> {
    if (input.purpose === "extension") return this.generateStickerImage({ prompt: input.prompt, references: input.references, mode: "generate", isolatedLayer: true, keepFrame: true });
    const label = input.prompt.replace(/[<&>]/g, "").slice(0, 24) || "Concept";
    const bytes = await sharp(
      Buffer.from(
        `<svg width="1024" height="1024" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1024" fill="#f4f0ff"/><rect x="96" y="96" width="832" height="640" rx="32" fill="none" stroke="#7c3aed" stroke-width="8" stroke-dasharray="24 16"/><text x="512" y="860" text-anchor="middle" font-family="system-ui" font-size="56" fill="#3b2a5a">${label}</text></svg>`,
      ),
    )
      .png()
      .toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }

  /**
   * A checked-in one-second clip: 480x480, 24 fps, H.264, a red square sliding across pure green.
   *
   * Real bytes rather than a stub, because everything downstream of the provider is the part worth
   * testing — `inspectMp4` has to accept the container, the asset row has to carry its timing, and
   * the document's fps has to be raised to match.
   */
  /** The mock's sheets are drawn to spec by construction, so there is never anything to reject. */
  async inspectSpriteSheet(input: AiSheetInspectionContext): Promise<AiSheetInspection> {
    return input.kind === "clips" && input.faceCompositing === "masked"
      ? { ok: true, faceFrames: Array.from({ length: input.sheet.count }, () => ({ faceX: 0.5, faceY: 0.42, faceSize: 0.3 })) }
      : { ok: true };
  }

  async generateStickerVideo(): Promise<AiVideoOutput> {
    const bytes = await readFile(path.join(process.cwd(), "fixtures", "video-480.mp4"));
    return { bytes: new Uint8Array(bytes), mimeType: "video/mp4", modelId: "mock/video" };
  }

  /**
   * Scripts the same create -> update -> show -> finalize shape the real loop produces, so the
   * integration tests exercise the session callbacks and the transcript rows they write.
   *
   * An instruction that asks for a turnaround plans its first layer as a `video` source, so the
   * build path's clip branch is exercised end to end.
   */
  async planSticker(
    input: AiPlanContext,
    session: PlanDraftingSession,
  ): Promise<PlanTurnResult | undefined> {
    // Deterministic so integration tests can assert exact layer ids and layout.
    const tokens = (
      input.instruction.match(/[\p{L}\p{N}]/gu) ?? ["A", "B"]
    ).slice(0, 8);
    const characters = tokens.length >= 2 ? tokens : ["A", "B"];
    const animated = input.stickerKind === "animated";
    const wantsClip = animated && /\b(rotat(?:e|es|ing)|spin(?:s|ning)?|turn(?:s|around|table)?)\b/i.test(input.instruction);
    // Mirrors the real planner's rule: selectable moods or poses mean a sprite character, and the
    // plan carries the controls that select them. The project's own switch says the same thing
    // without the user having had to word it that way, so it is honoured whatever they typed.
    const wantsSprite = input.controllable
      || /\b(mood|moods|expression|expressions|pose|poses|emotion|emotions)\b/i.test(input.instruction);
    if (animated && wantsSprite) {
      const clips = [
        { id: "idle", label: "Idle", prompt: "breathes gently and blinks once" },
        { id: "wave", label: "Wave", prompt: "raises one arm and waves it side to side" },
        { id: "bounce", label: "Bounce", prompt: "bounces up and settles gently" },
        { id: "dance", label: "Dance", prompt: "sways from side to side" },
        { id: "cheer", label: "Cheer", prompt: "raises both arms in celebration" },
        { id: "bow", label: "Bow", prompt: "bows forward and returns upright" },
        { id: "stretch", label: "Stretch", prompt: "stretches both arms overhead" },
        { id: "nod", label: "Nod", prompt: "nods twice and returns to rest" },
      ].slice(0, input.posePreset ? POSE_COUNTS[input.posePreset] : 2)
        .map((clip) => ({ ...clip, frames: Array.from({ length: 6 }, () => ({ duration: 0.5 })) }));
      const sprite = PlanV1Schema.parse({
        version: 1, title: "Controllable character", kind: "animated", timing: { durationSeconds: 3, fps: 24, loop: "loop" },
        posePreset: input.posePreset,
        summary: input.posePreset ? `Here is a controllable character with ${input.posePreset} pose variety. Confirm to build it.` : "Here is a controllable character with two clips and three expressions. Confirm to build it.",
        conceptPrompt: "A polished sticker of one round friendly character at rest, in a coherent bold style.",
        layers: [{ layerId: "hero", name: "Character", x: 0.5, y: 0.5, scaleX: 0.9, scaleY: 0.9, source: {
          kind: "sprite", prompt: "One round friendly character filling the frame on a transparent background.",
          face: "the round head: both eyes and the mouth sit in its centre; nothing facial elsewhere on the body",
          clips,
          expressions: [
            { id: "neutral", label: "Neutral", prompt: "calm open eyes and a small smile" },
            { id: "happy", label: "Happy", prompt: "closed curved eyes and a wide smile" },
            { id: "sad", label: "Sad", prompt: "downturned brows and a small frown" },
          ],
        } }],
        configuration: { controls: [
          { id: "mood", type: "choice", label: "Mood", defaultValue: "neutral", options: [{ id: "neutral", label: "Neutral" }, { id: "happy", label: "Happy" }, { id: "sad", label: "Sad" }] },
          { id: "pose", type: "choice", label: "Pose", defaultValue: "idle", options: clips.map(({ id, label }) => ({ id, label })) },
          { id: "speed", type: "number", label: "Speed", defaultValue: 1, minimum: 0.25, maximum: 2, step: 0.05, binding: "speed" },
        ], variants: [
          { id: "neutral", selections: { mood: "neutral" }, layers: [{ layerId: "hero", expression: "neutral" }] },
          { id: "happy", selections: { mood: "happy" }, layers: [{ layerId: "hero", expression: "happy" }] },
          { id: "sad", selections: { mood: "sad" }, layers: [{ layerId: "hero", expression: "sad" }] },
          ...clips.map(({ id }) => ({ id, selections: { pose: id }, layers: [{ layerId: "hero", clip: id }] })),
        ] },
      });
      const created = await session.createPlan(sprite);
      const finalized = await session.finalizePlan(created.planId);
      return { ...finalized, finalized: true };
    }
    // Mirrors the instruction the real planner is given: revising a sticker keeps the artwork it
    // already has, so the leading layers reuse it and only the surplus is drawn.
    const reusable = reusableAssetIds(input.document);
    const build = (staggered: boolean): PlanV1 =>
      PlanV1Schema.parse({
        version: 1,
        title: "Planned sticker",
        summary: wantsClip
          ? `Here is a plan with ${characters.length} layers; the first is generated as a video so it can turn around. Confirm to build it.`
          : `Here is a plan with ${characters.length} layers. Confirm to build it.`,
        kind: input.stickerKind,
        conceptPrompt: animated
          ? `A polished sticker spelling ${characters.join("").toUpperCase()}, with every character arranged left to right in one coherent bold style.`
          : undefined,
        timing: { durationSeconds: 2, fps: 30, loop: "loop" },
        layers: characters.map((token, index, all) => ({
          layerId: `part_${index}`,
          name: token.toUpperCase(),
          source: wantsClip && index === 0
            ? {
                kind: "video",
                prompt: `The single character "${token}" as a bold sticker letter filling the frame on a transparent background.`,
                motion: "A slow full turnaround, one complete rotation.",
                durationSeconds: 2,
              }
            : reusable[index]
              ? { kind: "existing", assetId: reusable[index] }
              : {
                  kind: "generate",
                  prompt: `The single character "${token}" as a bold sticker letter filling the frame on a transparent background.`,
                },
          x: (index + 0.5) / all.length,
          y: 0.5,
          scaleX: Math.min(0.9, 1 / all.length),
          scaleY: 0.6,
          animations:
            animated && staggered
              ? [
                  {
                    type: "popIn",
                    delay: Math.min(index * 0.2, 1.5),
                    duration: 0.4,
                    easing: "springBouncy",
                  },
                ]
              : [],
        })),
      });

    const created = await session.createPlan(build(false));
    const updated = await session.updatePlan(created.planId, build(true));
    await session.showPlan(updated.planId);
    const finalized = await session.finalizePlan(updated.planId);
    return { ...finalized, finalized: true };
  }

  async routeChatTurn(input: AiChatContext): Promise<AiChatAction> {
    if (process.env.NODE_ENV !== "production" && process.env.STICKER_FACTORY_E2E === "true") {
      const { chatModel } = await import("@/e2e/support/chat-model");
      return new GatewayAiProvider(chatModel()).routeChatTurn(input);
    }
    const instruction = input.instruction.trim();
    const normalized = instruction.toLowerCase();
    if (/\b(show|preview|see|display)\b/.test(normalized)) {
      return { type: "show", caption: "Here is the current sticker." };
    }
    if (
      /\b(plan|compose|typewriter|letter by letter|one at a time|separately)\b/.test(
        normalized,
      )
    ) {
      return { type: "plan", instruction };
    }
    if (
      input.stickerKind === "animated" &&
      /\b(animate|bounce|move|motion|rotate|spin|wiggle|wave|wipe|reveal|shine|sweep|glow|bloom)\b/.test(
        normalized,
      )
    ) {
      return { type: "animate", instruction };
    }
    // Narrower than the edit branch below on purpose: "add" alone still means edit, so the mock only
    // routes to a new layer when the request says so in as many words.
    if (
      input.document &&
      /\b(layer|alongside|next to it|on top of it)\b/.test(normalized)
    ) {
      return { type: "generate_image", instruction };
    }
    if (
      input.attachmentCount > 0 ||
      /\b(add|change|create|draw|edit|generate|make|remove|replace|recolor|turn)\b/.test(
        normalized,
      )
    ) {
      return input.document
        ? resolveChatAction(
            { type: "edit", instruction, imagePlacement: "replace" },
            input.document,
          )
        : { type: "generate", instruction };
    }
    return {
      type: "reply",
      message: "Tell me what you would like to change, animate, or preview.",
    };
  }
  async showSticker(
    _revisionId: string,
    kind: "static" | "animated",
  ): Promise<string> {
    return kind === "animated"
      ? "I updated the animation and attached it here. Tell me what you want to refine next."
      : "I updated the sticker and attached it here. Tell me what you want to refine next.";
  }
  async reply(): Promise<string> {
    return "Tell me what you would like to change, or ask me to animate it.";
  }
  /**
   * Names the project after the user's own most recent words, which is both a plausible summary and
   * a deterministic one — a mock that renamed a sticker differently on every run would make the
   * workflow tests unwritable.
   */
  async summarizeStickerTitle(input: AiTitleContext): Promise<string> {
    const lastUserLine = input.history
      .split("\n")
      .filter((line) => line.startsWith("user: "))
      .at(-1);
    if (!lastUserLine) return input.currentTitle;
    const words = lastUserLine.slice("user: ".length).trim().split(/\s+/);
    const named = words
      .slice(0, 4)
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
    return named || input.currentTitle;
  }
  /**
   * Picks the first option whose id or label appears in the sent sticker's title, so a test can
   * steer the pose with a title like "Sleepy Monday" without a model in the loop.
   */
  async choosePetStatus(input: AiPetStatusContext): Promise<AiPetStatus> {
    const title = input.sent.title.toLowerCase();
    const values: AiPetStatus["values"] = {};
    for (const control of input.controls) {
      if (control.type !== "choice") continue;
      const match = control.options.find((option) =>
        title.includes(option.id.toLowerCase()) || title.includes(option.label.toLowerCase()));
      if (match) values[control.id] = match.id;
    }
    return { values, caption: `Feeling ${input.sent.title}`, musings: [{ text: "Still thinking about it", afterMinutes: 20 }] };
  }
  async generatePetActions(input: AiPetActionsContext): Promise<Omit<PetAction, "id">[]> {
    return [
      { title: `Greet ${input.petTitle}`, description: `Say hello to ${input.petTitle}.`, effects: { happiness: 8, hp: 0, energy: -3, gold: 0 } },
      { title: `Dance with ${input.petTitle}`, description: `Move together with ${input.petTitle}.`, effects: { happiness: 14, hp: 0, energy: -12, gold: -5 } },
      { title: `Rest with ${input.petTitle}`, description: `Take a break beside ${input.petTitle}.`, effects: { happiness: 2, hp: 8, energy: 20, gold: 0 } },
    ];
  }
  async generatePetItems(input: AiPetItemsContext): Promise<AiPetItem[]> {
    const items: AiPetItem[] = [
      { title: `Bubble wand for ${input.petTitle}`, description: `Blow bubbles for ${input.petTitle} to chase.`,
        effects: { happiness: 8, hp: 0, energy: -3, gold: 0 }, kind: "toy", shelfHours: 30, keepsHours: 36 },
      { title: `Rubber ball for ${input.petTitle}`, description: `A bouncy ball to play fetch with ${input.petTitle}.`,
        effects: { happiness: 10, hp: 0, energy: -8, gold: -5 }, kind: "toy", shelfHours: 96, keepsHours: null },
      { title: `Weather snack for ${input.petTitle}`, description: "A treat inspired by today's weather.",
        effects: { happiness: 4, hp: 2, energy: -3, gold: -4 }, kind: "food", shelfHours: 20, keepsHours: 10 },
      { title: `Star tonic for ${input.petTitle}`, description: "A sparkling tonic that wakes a tired pet right up.",
        effects: { happiness: 3, hp: 0, energy: 40, gold: -35 }, kind: "food", shelfHours: 72, keepsHours: 240 },
      { title: `Day ticket for ${input.petTitle}`, description: `A ticket for an outing with ${input.petTitle}.`,
        effects: { happiness: 8, hp: 0, energy: -6, gold: -10 }, kind: "ticket", shelfHours: 48, keepsHours: 120 },
    ];
    const kept = new Set(input.keeping.map((item) => item.title));
    return items.filter((item) => !kept.has(item.title)).slice(0, input.maxCount);
  }
  async generatePetRooms(input: AiPetActionsContext): Promise<AiPetRoom[]> {
    return [
      { title: "Moss Burrow", description: `A soft, quiet den where ${input.petTitle} naps.`, scene: "A cozy mossy burrow with lanterns.",
        effects: { happiness: 1, hp: 0, energy: 5 }, price: 60 },
      { title: "Rooftop Garden", description: `Sun, flowers and breeze for ${input.petTitle}.`, scene: "A sunny rooftop garden at noon.",
        effects: { happiness: 6, hp: 0, energy: -2 }, price: 90 },
      { title: "Crystal Spring", description: `Healing water ${input.petTitle} can soak in.`, scene: "A glowing cave spring.",
        effects: { happiness: 0, hp: 6, energy: 1 }, price: 120 },
    ];
  }
  async generatePetRoomArt(input: AiPetRoomArtInput): Promise<AiImageOutput> {
    const label = input.scene.replace(/[<&>]/g, "").slice(0, 24) || "Room";
    const bytes = await sharp(Buffer.from(
      `<svg width="1024" height="1536" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1536" fill="#e6f2e0"/><rect x="312" y="160" width="400" height="360" fill="${input.windowKey.hex}"/><rect y="1000" width="1024" height="536" fill="#c9a77c"/><circle cx="170" cy="300" r="90" fill="#6b4a2f"/><circle cx="170" cy="300" r="78" fill="#FF00FF"/><rect x="770" y="600" width="200" height="140" fill="#3b2a1a"/><rect x="782" y="612" width="176" height="116" fill="#00FFFF"/><rect x="232" y="900" width="560" height="270" fill="#3b2a1a"/><rect x="246" y="914" width="532" height="242" fill="#FFFF00"/><text x="512" y="720" text-anchor="middle" font-family="system-ui" font-size="56" fill="#3b2a5a">${label}</text></svg>`,
    )).png().toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }
  async discoverPetThemes(input: AiPetThemeDiscoveryContext): Promise<AiPetTheme[]> {
    const none = { hours: null, weather: null, placeLabel: null, lastsHours: null };
    const everyday: AiPetTheme[] = [
      { ...none, title: "Corner Café", description: `A warm café where ${input.petTitle} gets a treat.`, scene: "A cosy corner café.",
        category: "restaurant", effects: { happiness: 2, hp: 1, energy: 3 }, dailyMinutes: 90 },
      { ...none, title: "Sunny Park", description: `Grass and puddles for ${input.petTitle}.`, scene: "A park with a pond.",
        category: "nature", effects: { happiness: 3, hp: 0, energy: -1 }, dailyMinutes: null },
    ];
    const needed: AiPetTheme[] = [
      ...(input.needs.includes("travel") ? [{ ...none, title: "Faraway Streets", description: `${input.petTitle} explores the trip.`,
        scene: "A bright street in a faraway town.", category: "travel" as const, effects: { happiness: 4, hp: 0, energy: -2 },
        dailyMinutes: null, placeLabel: "the trip", lastsHours: 72 }] : []),
      ...(input.needs.includes("accident") ? [{ ...none, title: "Pet Clinic", description: `Where ${input.petTitle} gets patched up.`,
        scene: "A clean little vet clinic.", category: "accident" as const, effects: { happiness: -1, hp: 5, energy: 1 },
        dailyMinutes: null, lastsHours: 24 }] : []),
    ];
    const known = new Set(input.known.map((theme) => theme.title));
    return [...needed, ...everyday.filter((theme) => !known.has(theme.title))].slice(0, input.max);
  }
  async choosePetTheme(input: AiPetThemeChoiceContext): Promise<AiPetThemeChoice> {
    const trip = input.candidates.find((candidate) => candidate.category === "travel");
    return trip && input.current?.id !== trip.id ? { move: true, themeId: trip.id, reason: "Off to see the trip!" } : { move: false };
  }
  async generatePetThemeArt(input: AiPetThemeArtInput): Promise<AiImageOutput> {
    const label = input.scene.replace(/[<&>]/g, "").slice(0, 24) || "Place";
    const bytes = await sharp(Buffer.from(
      `<svg width="1024" height="1536" xmlns="http://www.w3.org/2000/svg"><rect width="1024" height="1536" fill="#cfe8f7"/><rect y="1000" width="1024" height="536" fill="#8fbf73"/><circle cx="300" cy="380" r="90" fill="#4a5a6b"/><circle cx="300" cy="380" r="78" fill="#FF00FF"/><rect x="640" y="560" width="200" height="140" fill="#3b2a1a"/><rect x="652" y="572" width="176" height="116" fill="#00FFFF"/><rect x="232" y="900" width="560" height="270" fill="#3b2a1a"/><rect x="246" y="914" width="532" height="242" fill="#FFFF00"/><text x="512" y="720" text-anchor="middle" font-family="system-ui" font-size="56" fill="#3b2a5a">${label}</text></svg>`,
    )).png().toBuffer();
    return { bytes: new Uint8Array(bytes), mimeType: "image/png" };
  }
  async respondToPetInteraction(input: AiPetInteractionContext): Promise<AiPetStatus> {
    return { values: {}, caption: `${input.petTitle}: ${input.action.description}` };
  }
  async reactToPetPhoto(input: AiPetPhotoContext): Promise<AiPetStatus> {
    return { values: {}, caption: `${input.petTitle} loves this picture`, effects: { happiness: 5, hp: 0, energy: -1 } };
  }
  /** Strikes the first option of any choice control named in the owner's words; keeps the rest. */
  async decidePetPose(input: AiPetPoseContext): Promise<AiPetPose> {
    const words = input.words.toLowerCase();
    const values: AiPetPose["values"] = {};
    for (const control of input.controls) {
      if (control.type !== "choice") continue;
      const option = control.options.find((candidate) =>
        words.includes(candidate.id.toLowerCase()) || words.includes(candidate.label.toLowerCase()));
      if (option) values[control.id] = option.id;
    }
    return { values, animateEverySeconds: 20 };
  }
  async reactToPetSharedContent(input: AiPetSharedContentContext): Promise<AiPetStatus> {
    return { values: {}, caption: `${input.petTitle} read ${input.title ?? "your share"}` };
  }
  async generatePetPersona(input: AiPetPersonaContext): Promise<AiPetPersona> {
    return { class: "explorer", personality: `Curious ${input.petTitle}`, likes: ["walks"], dislikes: ["thunder"], favoriteWeather: "sunny" };
  }
  async searchPetHeadlines(): Promise<string[]> {
    return ["Local park opens a new dog run"];
  }
  async narratePetEvent(input: AiPetEventContext): Promise<AiPetStatus> {
    return { values: {}, caption: `${input.petTitle}: ${input.event.title}`, musings: [{ text: "What next?", afterMinutes: 15 }] };
  }
  async generatePetEncounter(input: AiPetEncounterContext): Promise<AiPetEncounter> {
    return {
      title: "A stray kitten",
      prompt: `${input.petTitle} found a kitten shivering by the door. What should we do?`,
      choices: [
        { title: "Bring it a blanket", description: "Wrap it up warm.", correct: true, outcome: "The kitten purred and left a coin behind.",
          effects: { happiness: 6, hp: 0, energy: 0, gold: 8 }, medicine: 0, sickens: false },
        { title: "Chase it away", description: "Shoo it off.", correct: false, outcome: "That felt mean. Now I'm sad.",
          effects: { happiness: -8, hp: 0, energy: -3, gold: 0 }, medicine: 0, sickens: false },
        { title: "Share a nap", description: "Curl up together outside.", correct: false, outcome: "It was cold out there… achoo!",
          effects: { happiness: 0, hp: -5, energy: -2, gold: 0 }, medicine: 0, sickens: true },
      ],
    };
  }
  async meetPetFriend(input: AiPetFriendContext): Promise<AiPetFriend> {
    return {
      name: "Puddle",
      brief: "A round little raindrop sprite with big shiny eyes and a tiny leaf umbrella, who bounces when happy.",
      story: `${input.petTitle} met Puddle splashing by the window.`,
      greeting: "This is Puddle! We splashed together all afternoon.",
    };
  }
  async noticePetSticker(input: AiPetStickerContext): Promise<AiPetStickerReaction> {
    return { react: true, values: {}, caption: `${input.petTitle} likes ${input.made.title}`, effects: { happiness: 2, hp: 0, energy: 0 } };
  }
  /**
   * A bag of words, hashed into the embedding's width and normalized: texts sharing words land
   * close together, so finding memories by meaning works in tests without a model.
   */
  async embedPetMemories(values: string[]): Promise<number[][]> {
    return values.map((value) => {
      const vector = new Array<number>(PET_MEMORY_DIMENSIONS).fill(0);
      for (const word of value.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
        let hash = 0;
        for (const char of word) hash = (hash * 31 + char.codePointAt(0)!) >>> 0;
        vector[hash % PET_MEMORY_DIMENSIONS] += 1;
      }
      const length = Math.hypot(...vector);
      // A text with no words still needs a direction for cosine distance to be defined.
      return length ? vector.map((entry) => entry / length) : vector.map((_, index) => (index === 0 ? 1 : 0));
    });
  }
  /** One memory per moment; a moment it already remembers word for word becomes more important instead. */
  async updatePetMemory(input: AiPetMemoryContext): Promise<AiPetMemoryOperation[]> {
    return input.moments.map((moment): AiPetMemoryOperation => {
      const content = `${moment.title}: ${moment.detail}`.slice(0, 200);
      const known = input.memories.find((memory) => memory.content === content);
      return known
        ? { op: "update", id: known.id, content, category: known.category, importance: Math.min(5, known.importance + 1) }
        : { op: "add", content, category: moment.kind === "talk" ? "owner" : "experience", importance: 2 };
    });
  }

}
