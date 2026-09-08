import { afterEach, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import sharp from "sharp";
import { getAiProvider, setAiProviderForTests, type AiTitleContext } from "@/lib/ai/gateway";
import { PlanV1Schema } from "@/lib/contracts/plan";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { firstRow, setDatabaseForTests } from "@/lib/db/client";
import { assets, generationJobs, plans as planRows, stickerRevisions, stickers, users } from "@/lib/db/schema";
import { cancelPlan, confirmPlan } from "@/lib/services/plans";
import { acceptRevision, createChatTurn, createSticker, listChatMessages } from "@/lib/services/stickers";
import { MemoryObjectStore, objectKey, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";
import { unusedAiProvider, resetWorkflowTestState, drawnAnimatedBase, attachedBytes, attachablePhoto } from "@/tests/helpers/workflow";

describe("durable sticker workflow: agent context", () => {
  afterEach(resetWorkflowTestState);

  it("shows the router and the planner the photo the user attached", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-sees", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-sees");

    let routed: number[][] | undefined;
    let planned: number[][] | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => {
        routed = attachedBytes(input.references);
        return { type: "plan", instruction: input.instruction };
      },
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 1024, height: 1024, channels: 4, background: { r: 200, g: 120, b: 60, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        planned = attachedBytes(input.references);
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Me", summary: "A sticker of you.", kind: "animated",
          conceptPrompt: "A polished sticker of the person in the attached photo, waving, filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "hero", name: "Me",
            source: { kind: "generate", prompt: "The person from the photo as a sticker on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-sees", { title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [photo.id] });
    const turn = await createChatTurn(db, "owner-sees", sticker.stickerId, {
      text: "Make a sticker of me",
      intent: "chat",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    // Both models used to be told a number of attachments and nothing else, which is how a design
    // for "a sticker of me" got drafted without anyone having looked at the person.
    expect(routed).toEqual([photo.bytes]);
    expect(planned).toEqual([photo.bytes]);
    await close();
  });

  it("shows the router a previous plan image and reuses it when a text-only follow-up asks", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-plan-image", createdAt: new Date(), updatedAt: new Date() });

    const conceptBytes = new Uint8Array(await sharp({
      create: { width: 1024, height: 1024, channels: 4, background: { r: 230, g: 90, b: 150, alpha: 1 } },
    }).png().toBuffer());
    const generatedSubject = await sharp({
      create: { width: 640, height: 640, channels: 4, background: { r: 80, g: 170, b: 240, alpha: 1 } },
    }).png().toBuffer();
    const generatedBytes = new Uint8Array(await sharp({
      create: { width: 1024, height: 1024, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
    }).composite([{ input: generatedSubject, left: 192, top: 192 }]).png().toBuffer());
    let routedPlanImage: number[] | undefined;
    let generatedReferences: number[][] | undefined;
    let generatedMode: "generate" | "conversation_edit" | undefined;

    setAiProviderForTests({
      ...unusedAiProvider,
      planSticker: async (_input, session) => {
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Cartoon Words", summary: "Cartoon lettering with a playful bounce.", kind: "animated",
          conceptPrompt: "Colourful cartoon lettering as a polished sticker filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "words", name: "Words",
            source: { kind: "generate", prompt: "Colourful cartoon lettering on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
      generateConceptImage: async () => ({ bytes: conceptBytes, mimeType: "image/png" }),
      routeChatTurn: async (input) => {
        const planVisual = input.priorArt.find((visual) => visual.label.includes("previous plan"));
        routedPlanImage = planVisual ? [...planVisual.image.bytes] : undefined;
        return { type: "generate", instruction: input.instruction, usePlanImage: true };
      },
      generateStickerImage: async (input) => {
        generatedReferences = attachedBytes(input.references);
        generatedMode = input.mode;
        return { bytes: generatedBytes, mimeType: "image/png" };
      },
      showSticker: async () => "Generated from the plan image.",
    });

    const sticker = await createSticker(db, "owner-plan-image", {
      title: "Cartoon Words", kind: "animated", prompt: "Cartoon words", referenceAssetIds: [],
    });
    const planTurn = await createChatTurn(db, "owner-plan-image", sticker.stickerId, {
      text: "Plan some cartoon words", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(planTurn.jobId)).workflowStatus).toBe("succeeded");

    const [pending] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    await cancelPlan(db, "owner-plan-image", sticker.stickerId, pending.id);

    const reuseTurn = await createChatTurn(db, "owner-plan-image", sticker.stickerId, {
      text: "Use the plan image as the reference", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(reuseTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(routedPlanImage?.length).toBeGreaterThan(0);
    expect(generatedReferences?.[0]).toEqual(routedPlanImage);
    expect(generatedMode).toBe("conversation_edit");
    await close();
  });

  it("shows the planner the existing artwork on a turn with nothing attached", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-replan", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-replan", { title: "Cloud", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-replan", sticker.stickerId, "Happy cloud");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    const baseRevision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId)).then(firstRow);
    await acceptRevision(db, "owner-replan", sticker.stickerId, baseRevision!.id);

    let planned: { references: number; priorArt: Array<{ label: string; bytes: number }> } | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 1024, height: 1024, channels: 4, background: { r: 200, g: 120, b: 60, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        planned = {
          references: input.references.length,
          priorArt: input.priorArt.map((visual) => ({
            label: visual.label,
            bytes: visual.image.bytes.byteLength,
          })),
        };
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Cloud", summary: "Bigger cloud.", kind: "animated",
          conceptPrompt: "A polished sticker of a happy cloud, filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "hero", name: "Cloud",
            source: { kind: "generate", prompt: "A happy cloud on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const replan = await createChatTurn(db, "owner-replan", sticker.stickerId, {
      text: "make the cloud bigger",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(replan.jobId)).workflowStatus).toBe("succeeded");

    // The regression this guards: the planner was shown `references` and nothing else, so a turn
    // where the user attached nothing — every "make it bigger", every re-plan — was designed from
    // JSON and prose with no sight of the artwork, and came back having redrawn things nobody had
    // asked it to touch.
    expect(planned?.references).toBe(0);
    expect(planned?.priorArt.length).toBeGreaterThan(0);
    // An animated project renders as a sheet of sampled frames, and the label has to say so — a
    // planner that reads one as a single composition sees the same subject drawn six times over.
    expect(planned?.priorArt[0].label).toContain("contact sheet");
    expect(planned?.priorArt[0].label).toContain("review render");
    // Real pixels, not an empty buffer that happens to satisfy the type.
    for (const visual of planned!.priorArt) expect(visual.bytes).toBeGreaterThan(0);
    await close();
  });

  it("keeps a capture usable on later turns that attach nothing", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-capture", createdAt: new Date(), updatedAt: new Date() });

    // A Live Photo capture, cut out on device: 12 frames in a 4x3 atlas, the shape the iOS client
    // uploads and the shape a plan has to copy verbatim.
    const captureId = crypto.randomUUID();
    const captureKey = objectKey("owner-capture", captureId, "image/png");
    const captureBytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
    await db.insert(assets).values({
      id: captureId, ownerId: "owner-capture", kind: "sequence", state: "ready",
      r2Key: captureKey, mimeType: "image/png", byteSize: captureBytes.byteLength,
      frameCount: 12, fps: 24, sequenceColumns: 4, sequenceRows: 3,
      createdAt: new Date(), readyAt: new Date(),
    });
    await store.put(captureKey, { bytes: captureBytes, contentType: "image/png" });

    const sequenceLayer = (assetId: string) => ({
      layerId: "hero", name: "Me",
      source: { kind: "sequence", assetId, columns: 4, rows: 3, frameCount: 12, frameRate: 24 },
      x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
    });
    const planWith = (title: string, layers: unknown[]) => PlanV1Schema.parse({
      title, summary: `${title}.`, kind: "animated",
      conceptPrompt: "A polished sticker of the person in the capture, filling the frame.",
      timing: { durationSeconds: 2, fps: 30, loop: "loop" },
      layers,
    });

    const seen: Array<{ captures: string[]; priorArt: string[]; attached: number }> = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async () => ({
        bytes: new Uint8Array(await sharp({
          create: { width: 512, height: 512, channels: 4, background: { r: 30, g: 90, b: 200, alpha: 1 } },
        }).png().toBuffer()),
        mimeType: "image/png",
      }),
      planSticker: async (input, session) => {
        seen.push({
          captures: input.sequenceAssets.map((asset) =>
            `${asset.assetId}:${asset.columns}x${asset.rows}:${asset.frameCount}@${asset.frameRate}`),
          priorArt: input.priorArt.map((visual) => visual.label),
          attached: input.references.length,
        });
        const created = await session.createPlan(planWith("Me", [sequenceLayer(captureId)]));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-capture", {
      title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [captureId],
    });
    const first = await createChatTurn(db, "owner-capture", sticker.stickerId, {
      text: "我要我的头像有个会动的皇冠",
      intent: "chat",
      attachments: [{ assetId: captureId, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");

    // The turn that used to break it: a request to add text, with nothing attached.
    const second = await createChatTurn(db, "owner-capture", sticker.stickerId, {
      text: "加一个文字： 游戏大神",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(second.jobId)).workflowStatus).toBe("succeeded");

    expect(seen).toHaveLength(2);
    const [attachTurn, textOnlyTurn] = seen;
    expect(attachTurn.captures).toEqual([`${captureId}:4x3:12@24`]);

    // The regression. This turn attached nothing, and the capture used to vanish with it — not just
    // from view but from `sequenceAssets`, which made the `sequence` source illegal and left the
    // planner no way to keep the user's own footage. It answered by replacing them with a generate
    // layer describing their face.
    expect(textOnlyTurn.attached).toBe(0);
    expect(textOnlyTurn.captures).toEqual([`${captureId}:4x3:12@24`]);
    // And it is shown the footage, not merely told the numbers.
    expect(textOnlyTurn.priorArt[0]).toContain("captured");
    expect(textOnlyTurn.priorArt[0]).toContain("contact sheet");

    // The plan the second turn produced still points at the capture rather than at a drawn stand-in.
    const stored = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    const newest = stored.sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime()).at(-1);
    expect(newest?.planJson.layers[0].source).toMatchObject({ kind: "sequence", assetId: captureId });
    await close();
  });

  it("still renders the concept from the user's photo on a later turn that attaches nothing", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-likeness", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-likeness");

    const conceptReferences: number[][][] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async (input) => ({ type: "plan", instruction: input.instruction }),
      generateConceptImage: async (input) => {
        conceptReferences.push(attachedBytes(input.references));
        return {
          bytes: new Uint8Array(await sharp({
            create: { width: 1024, height: 1024, channels: 4, background: { r: 90, g: 60, b: 30, alpha: 1 } },
          }).png().toBuffer()),
          mimeType: "image/png",
        };
      },
      planSticker: async (input, session) => {
        const created = await session.createPlan(PlanV1Schema.parse({
          title: "Me", summary: "A sticker of you.", kind: "animated",
          conceptPrompt: "The person in the supplied reference photo, as a polished sticker filling the frame.",
          timing: { durationSeconds: 2, fps: 30, loop: "loop" },
          layers: [{
            layerId: "portrait", name: "Me",
            source: { kind: "generate", prompt: "The person in the supplied reference photo, on a transparent background." },
            x: 0.5, y: 0.5, scaleX: 0.8, scaleY: 0.8,
          }],
        }));
        const finalized = await session.finalizePlan(created.planId);
        return { ...finalized, finalized: true };
      },
    });

    const sticker = await createSticker(db, "owner-likeness", {
      title: "Me", kind: "animated", prompt: "Me", referenceAssetIds: [photo.id],
    });
    const first = await createChatTurn(db, "owner-likeness", sticker.stickerId, {
      text: "Add a crown on top of my head",
      intent: "chat",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");

    const second = await createChatTurn(db, "owner-likeness", sticker.stickerId, {
      text: "Add text game master",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(second.jobId)).workflowStatus).toBe("succeeded");

    // The image model is the only thing in the pipeline that ever sees a photograph, and it used to
    // see one only on the turn it was uploaded. A second turn with nothing attached and no built
    // document rendered its concept from the plan's prose alone — and prose cannot carry a face, so
    // the person came back a stranger who merely matched the adjectives.
    expect(conceptReferences).toHaveLength(2);
    expect(conceptReferences[0]).toEqual([photo.bytes]);
    expect(conceptReferences[1]).toEqual([photo.bytes]);
    await close();
  });

  it("shows the animator the photo the user attached", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-animates", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-animates");

    const sticker = await createSticker(db, "owner-animates", { title: "Wave", kind: "animated", prompt: "Happy cloud", referenceAssetIds: [] });
    const baseTurn = await drawnAnimatedBase(db, "owner-animates", sticker.stickerId, "Happy cloud");
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    await acceptRevision(db, "owner-animates", sticker.stickerId, baseTurn.jobId);

    let animated: number[][] | undefined;
    setAiProviderForTests({
      ...unusedAiProvider,
      animateSticker: async (input, session) => {
        animated = attachedBytes(input.references);
        const created = await session.createAnimation([{
          op: "setScaleKeyframes",
          layerId: "hero",
          keyframes: [
            { timeSeconds: 0, x: 1, y: 1, easing: "easeOut" },
            { timeSeconds: 1, x: 1.1, y: 1.1, easing: "easeIn" },
          ],
        }]);
        const finalized = await session.finalizeAnimation(created.animationId);
        return { animationId: finalized.animationId, revision: finalized.revision, finalized: true };
      },
      showSticker: async () => "Here is the motion.",
    });

    const turn = await createChatTurn(db, "owner-animates", sticker.stickerId, {
      text: "Make it wave like the person in this photo",
      intent: "animate",
      targetLayerId: "hero",
      baseRevisionId: baseTurn.jobId,
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    // The animation loop draws nothing, so an attachment on an animate turn is only ever there to
    // be looked at — and until now it was the one turn that never loaded it at all.
    expect(animated).toEqual([photo.bytes]);
    await close();
  }, 30_000);

  it("revises a built sticker by reusing its artwork instead of paying to redraw it", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-f", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-f", { title: "HI", kind: "animated", prompt: "HI", referenceAssetIds: [] });
    const first = await createChatTurn(db, "owner-f", sticker.stickerId, {
      text: "Compose the word HI letter by letter", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(first.jobId);
    const drafted = (await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId))).at(0)!;
    const built = await confirmPlan(db, "owner-f", sticker.stickerId, drafted.id);
    await stickerGenerationWorkflow(built.jobId);
    await acceptRevision(db, "owner-f", sticker.stickerId, built.jobId);

    const originalAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    const originalAssetIds = originalAssets.map((asset) => asset.id).sort();
    expect(originalAssets.some((asset) => asset.kind === "preview")).toBe(true);

    // A second planning turn against the sticker that now exists. Nothing about it is new artwork,
    // so the plan carries the layers it already has rather than describing them again.
    const revise = await createChatTurn(db, "owner-f", sticker.stickerId, {
      text: "Plan it tighter", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(revise.jobId)).workflowStatus).toBe("succeeded");

    const revised = (await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .find((row) => row.state === "finalized")!;
    const reusedIds = revised.planJson.layers.map((layer) => (layer.source as { assetId?: string }).assetId);
    expect(revised.planJson.layers.every((layer) => layer.source.kind === "existing")).toBe(true);
    expect(reusedIds.every((assetId) => originalAssetIds.includes(assetId!))).toBe(true);

    // The card says as much: nothing to generate, so the user is asked to build rather than to pay.
    const card = (await listChatMessages(db, "owner-f", sticker.stickerId)).data
      .filter((message) => message.kind === "plan").at(-1);
    expect(card?.plan?.generationCount).toBe(0);

    const rebuilt = await confirmPlan(db, "owner-f", sticker.stickerId, revised.id);
    expect((await stickerGenerationWorkflow(rebuilt.jobId)).workflowStatus).toBe("succeeded");

    // Re-planning creates one new static reference for the new decision. Building it creates no new
    // master images, and the document still points at exactly the artwork previously approved.
    const finalAssets = await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId));
    expect(finalAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort())
      .toEqual(originalAssets.filter((asset) => asset.kind === "master").map((asset) => asset.id).sort());
    expect(finalAssets.map((asset) => asset.id).sort())
      .toEqual([...originalAssetIds, revised.conceptAssetId!].sort());
    const revision = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, rebuilt.jobId)).then(firstRow);
    const document = StickerDocumentSchema.parse(revision!.documentJson);
    expect(document.layers.flatMap((layer) => (layer.type === "image" ? [layer.assetId] : [])).sort())
      .toEqual(reusedIds.sort());
    await close();
  });

  it.each(["draft", "finalized"] as const)("keeps follow-up chat in planning while a plan is %s", async (state) => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-pending", createdAt: new Date(), updatedAt: new Date() });
    const sticker = await createSticker(db, "owner-pending", {
      title: "HI", kind: "static", prompt: "HI", referenceAssetIds: [],
    });
    const first = await createChatTurn(db, "owner-pending", sticker.stickerId, {
      text: "Compose the word HI from separate letters", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(first.jobId)).workflowStatus).toBe("succeeded");
    const [pending] = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    await db.update(planRows).set({ state }).where(eq(planRows.id, pending.id));
    const mockProvider = getAiProvider();
    const instructions: string[] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      planSticker: async (input, session) => {
        instructions.push(input.instruction);
        expect(input.history).toContain("Current pending plan");
        return mockProvider.planSticker(input, session);
      },
      generateConceptImage: mockProvider.generateConceptImage.bind(mockProvider),
    });
    for (const text of ["Make the letters blue", "Add more spacing"]) {
      const followup = await createChatTurn(db, "owner-pending", sticker.stickerId, {
        text, intent: "chat", attachments: [], imagePlacement: "replace",
      });
      expect((await stickerGenerationWorkflow(followup.jobId)).workflowStatus).toBe("succeeded");
    }
    expect(instructions).toEqual(["Make the letters blue", "Add more spacing"]);
    const rows = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(rows).toHaveLength(3);
    expect(rows.filter((row) => row.state === "finalized")).toHaveLength(1);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.stickerId, sticker.stickerId)))
      .toHaveLength(0);
    await close();
  });

  it("refuses to act on a plan that is no longer actionable", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-d", createdAt: new Date(), updatedAt: new Date() });

    const sticker = await createSticker(db, "owner-d", { title: "HI", kind: "static", prompt: "HI", referenceAssetIds: [] });
    const first = await createChatTurn(db, "owner-d", sticker.stickerId, {
      text: "Compose the word HI from separate letters",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(first.jobId);
    const second = await createChatTurn(db, "owner-d", sticker.stickerId, {
      text: "Actually compose it one at a time with more spacing",
      intent: "chat",
      attachments: [],
      imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(second.jobId);

    // A second planning turn starts a fresh plan and supersedes the previous one, so only one plan
    // is ever actionable, and the new row links back to what it replaced.
    const plans = await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId));
    expect(plans).toHaveLength(2);
    expect(plans.filter((plan) => plan.state === "finalized")).toHaveLength(1);
    const superseded = plans.find((plan) => plan.state === "superseded")!;
    const live = plans.find((plan) => plan.state === "finalized")!;
    expect(live.supersedesId).toBe(superseded.id);
    await expect(confirmPlan(db, "owner-d", sticker.stickerId, superseded.id))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });

    // A dismissal records why, so the next planning turn can be told what was turned down.
    expect(await cancelPlan(db, "owner-d", sticker.stickerId, live.id, "Too cramped"))
      .toMatchObject({ state: "cancelled" });
    expect((await db.select().from(planRows).where(eq(planRows.id, live.id)).then(firstRow))?.decisionReason)
      .toBe("Too cramped");
    await expect(confirmPlan(db, "owner-d", sticker.stickerId, live.id))
      .rejects.toMatchObject({ code: "PLAN_NOT_ACTIONABLE" });
    await close();
  });
  it("lets project creation itself propose a composition instead of one flat image", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-e", createdAt: new Date(), updatedAt: new Date() });

    // The creation endpoint uses intent "generate", which never reaches the chat router. A first
    // prompt asking for a per-element effect must still be able to become a plan, because a
    // single flat image can never be keyframed into a typewriter reveal afterwards.
    const sticker = await createSticker(db, "owner-e", {
      title: "HI", kind: "animated", prompt: "Typewriter effect typing the word Hi", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-e", sticker.stickerId, {
      text: "Typewriter effect typing the word Hi",
      intent: "generate",
      attachments: [],
      imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, sticker.stickerId)))
      .toHaveLength(1);
    expect(await db.select().from(assets).where(eq(assets.stickerId, sticker.stickerId)))
      .toEqual([expect.objectContaining({ kind: "preview", state: "ready" })]);
    await close();
  });

  it("plans an animated creation however plain its prompt, and draws a static one", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-f", createdAt: new Date(), updatedAt: new Date() });

    // "A happy cloud" asks for no per-element effect at all. It is still planned, because the kind
    // is the user's standing choice and one flat image would quietly hand them the static sticker
    // they did not pick — the reading of their words is not what decides this.
    const animated = await createSticker(db, "owner-f", {
      title: "Cloud", kind: "animated", prompt: "A happy cloud", referenceAssetIds: [],
    });
    const animatedTurn = await createChatTurn(db, "owner-f", animated.stickerId, {
      text: "A happy cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(animatedTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, animated.stickerId)))
      .toHaveLength(1);
    // Only the static visual reference is drawn until the user confirms the plan.
    expect(await db.select().from(assets).where(eq(assets.stickerId, animated.stickerId)))
      .toEqual([expect.objectContaining({ kind: "preview", state: "ready" })]);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, animatedTurn.jobId)).then(firstRow))
      .toBeFalsy();

    // A static project never moves, so there is nothing to design as layers: it is drawn straight.
    const still = await createSticker(db, "owner-f", {
      title: "Cloud", kind: "static", prompt: "A happy cloud", referenceAssetIds: [],
    });
    const stillTurn = await createChatTurn(db, "owner-f", still.stickerId, {
      text: "A happy cloud", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(stillTurn.jobId)).workflowStatus).toBe("succeeded");

    expect(await db.select().from(planRows).where(eq(planRows.stickerId, still.stickerId))).toHaveLength(0);
    expect(await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, stillTurn.jobId)).then(firstRow)).toBeTruthy();
    await close();
  });

  it("draws a quick-mode turn on the quick image model and leaves every other turn alone", async () => {
    const { db, close } = await createTestDatabase();
    const store = new MemoryObjectStore();
    setDatabaseForTests(db);
    setObjectStoreForTests(store);
    process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
    await db.insert(users).values({ id: "owner-quick", createdAt: new Date(), updatedAt: new Date() });
    const photo = await attachablePhoto(db, store, "owner-quick");

    const mockProvider = getAiProvider();
    const drawnQuickly: Array<boolean | undefined> = [];
    // Everything a turn can ask a reasoning model for, counted. Quick mode's whole latency budget is
    // spent on these rather than on the draw: each is a vision call on the orchestrator model, and
    // together they cost several times the two seconds the quick model needs for the picture.
    const orchestrated = { selected: 0, shown: 0, named: 0 };
    setAiProviderForTests({
      ...unusedAiProvider,
      selectImageReferences: async (input) => {
        orchestrated.selected += 1;
        return mockProvider.selectImageReferences(input);
      },
      generateStickerImage: async (input) => {
        drawnQuickly.push(input.quick);
        return mockProvider.generateStickerImage(input);
      },
      editSticker: mockProvider.editSticker.bind(mockProvider),
      showSticker: async (...args) => {
        orchestrated.shown += 1;
        return mockProvider.showSticker(...args);
      },
      summarizeStickerTitle: async (input) => {
        orchestrated.named += 1;
        return mockProvider.summarizeStickerTitle(input);
      },
    });

    const sticker = await createSticker(db, "owner-quick", {
      title: "Wink", kind: "static", prompt: "A winking cat", referenceAssetIds: [photo.id],
    });
    const fromMessages = await createChatTurn(db, "owner-quick", sticker.stickerId, {
      text: "A winking cat",
      intent: "generate",
      attachments: [{ assetId: photo.id, kind: "reference" }],
      imagePlacement: "replace",
      quick: true,
    });
    expect((await stickerGenerationWorkflow(fromMessages.jobId, true)).workflowStatus).toBe("succeeded");

    // One model call for the whole turn: the drawing. Not the reference selector, not the caption,
    // not the renaming — all three deliberate on artwork nobody in Messages is going to read a
    // sentence about, while the person who asked watches a spinner.
    expect(orchestrated).toEqual({ selected: 0, shown: 0, named: 0 });
    // The transcript still gets its assistant message, or the main app has a turn it cannot draw.
    const transcript = await listChatMessages(db, "owner-quick", sticker.stickerId, { limit: 10 });
    expect(transcript.data.at(-1)).toMatchObject({ role: "assistant", content: "Here's your sticker." });

    // The same project, carried on in the main app: the flag belongs to the turn, so opening a
    // sticker made in Messages does not condemn the rest of its life to the cheaper model — or to
    // the shortcuts, which is why the orchestrator counts move again here.
    const fromApp = await createChatTurn(db, "owner-quick", sticker.stickerId, {
      text: "Give it a party hat", intent: "edit", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(fromApp.jobId)).workflowStatus).toBe("succeeded");

    expect(drawnQuickly).toEqual([true, false]);
    expect(orchestrated.named).toBe(1);
    await close();
  });

  it("renames the sticker from its transcript when the turn finishes", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title", createdAt: new Date(), updatedAt: new Date() });

    const summarized: AiTitleContext[] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async (input) => {
        summarized.push(input);
        // Quoted and padded, the way a model that ignored half the instruction answers.
        return ' "Sunglasses Cat" ';
      },
    });

    const prompt = "make me a cat sticker wearing tiny sunglasses please";
    const sticker = await createSticker(db, "owner-title", {
      title: prompt, kind: "static", prompt, referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title", sticker.stickerId, {
      text: prompt, intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title)
      .toBe("Sunglasses Cat");
    expect(summarized).toHaveLength(1);
    expect(summarized[0].currentTitle).toBe(prompt);
    expect(summarized[0].history).toContain(`user: ${prompt}`);
    // Tool-call rows are the turn's machinery. `reply` is the one this turn opened, and naming the
    // sticker after it is exactly what filtering them out prevents.
    expect(summarized[0].history).not.toContain("system: reply");
    await close();
  });

  it("keeps the old name, and the finished turn, when naming fails", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title-fail", createdAt: new Date(), updatedAt: new Date() });

    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async () => { throw new Error("naming timed out"); },
    });

    const sticker = await createSticker(db, "owner-title-fail", {
      title: "Wave", kind: "static", prompt: "Wave", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title-fail", sticker.stickerId, {
      text: "Hello", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(turn.jobId)).workflowStatus).toBe("succeeded");

    expect((await db.select().from(generationJobs).where(eq(generationJobs.id, turn.jobId)).then(firstRow))?.state)
      .toBe("succeeded");
    expect((await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title)
      .toBe("Wave");
    await close();
  });

  it("clips a name too long for a library row at a word boundary", async () => {
    const { db, close } = await createTestDatabase();
    setDatabaseForTests(db);
    setObjectStoreForTests(new MemoryObjectStore());
    await db.insert(users).values({ id: "owner-title-long", createdAt: new Date(), updatedAt: new Date() });

    setAiProviderForTests({
      ...unusedAiProvider,
      routeChatTurn: async () => ({ type: "reply", message: "Tell me what to draw." }),
      summarizeStickerTitle: async () =>
        "A Very Enthusiastic Cat Wearing Tiny Mirrored Sunglasses On A Skateboard",
    });

    const sticker = await createSticker(db, "owner-title-long", {
      title: "Cat", kind: "static", prompt: "Cat", referenceAssetIds: [],
    });
    const turn = await createChatTurn(db, "owner-title-long", sticker.stickerId, {
      text: "Cat on a skateboard", intent: "chat", attachments: [], imagePlacement: "replace",
    });
    await stickerGenerationWorkflow(turn.jobId);

    const title = (await db.select().from(stickers).where(eq(stickers.id, sticker.stickerId)).then(firstRow))?.title;
    expect(title).toBe("A Very Enthusiastic Cat Wearing Tiny Mirrored");
    expect(title!.length).toBeLessThanOrEqual(48);
    await close();
  });
});
