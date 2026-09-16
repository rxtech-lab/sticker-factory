// The provider used by tests and by local runs with `STICKER_FACTORY_MOCK_SERVICES=true`.

import { readFile } from "node:fs/promises";
import path from "node:path";
import { POSE_COUNTS } from "@/lib/contracts/pose-preset";
import sharp from "sharp";
import { configurationReviewSelections } from "@/lib/contracts/configuration";
import { PlanV1Schema, reusableAssetIds, type PlanV1 } from "@/lib/contracts/plan";
import { type StickerOperationV1 } from "@/lib/contracts/sticker";
import { normalizeTransparentPng } from "@/lib/storage/r2";
import { GatewayAiProvider } from "./gateway";
import { resolveChatAction } from "./gateway-contracts";
import type { AiAnimationContext, AiChatAction, AiChatContext, AiEditContext, AiImageInput, AiImageOutput, AiLayoutContext, AiPlanContext, AiProvider, AiReferenceSelectionContext, AiSheetInspection, AiSheetInspectionContext, AiTitleContext, AiVideoOutput, AnimateTurnResult, AnimationDraftingSession, EditDraftingSession, EditTurnResult, LayoutDraftingSession, LayoutTurnResult, PlanDraftingSession, PlanTurnResult } from "./gateway-contracts";

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
    void input;
    return { ok: true };
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
}
