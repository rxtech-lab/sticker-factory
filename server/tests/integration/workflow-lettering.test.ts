import { afterEach, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { getAiProvider, setAiProviderForTests, type AiImageInput } from "@/lib/ai/gateway";
import { StickerDocumentSchema } from "@/lib/contracts/sticker";
import { setDatabaseForTests } from "@/lib/db/client";
import { stickerRevisions, users } from "@/lib/db/schema";
import { acceptRevision, createChatTurn, createSticker } from "@/lib/services/stickers";
import { MemoryObjectStore, setObjectStoreForTests } from "@/lib/storage/r2";
import { createTestDatabase } from "@/tests/helpers/database";
import { resetWorkflowTestState, unusedAiProvider } from "@/tests/helpers/workflow";
import { stickerGenerationWorkflow } from "@/workflows/sticker-generation";

afterEach(resetWorkflowTestState);

it.each(["add", "replace"] as const)("scopes %s lettering generation without losing existing artwork", async (placement) => {
  const { db, close } = await createTestDatabase();
  setDatabaseForTests(db);
  setObjectStoreForTests(new MemoryObjectStore());
  process.env.STICKER_FACTORY_MOCK_SERVICES = "true";
  try {
    const ownerId = "lettering-owner";
    await db.insert(users).values({ id: ownerId, createdAt: new Date(), updatedAt: new Date() });
    const mock = getAiProvider();
    const sticker = await createSticker(db, ownerId, {
      title: "Car", kind: "static", prompt: "A red car on an orange road", referenceAssetIds: [],
    });
    const baseTurn = await createChatTurn(db, ownerId, sticker.stickerId, {
      text: "A red car on an orange road", intent: "generate", attachments: [], imagePlacement: "replace",
    });
    expect((await stickerGenerationWorkflow(baseTurn.jobId)).workflowStatus).toBe("succeeded");
    await acceptRevision(db, ownerId, sticker.stickerId, baseTurn.jobId);
    const [baseRow] = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, baseTurn.jobId));
    const base = StickerDocumentSchema.parse(baseRow.documentJson);
    const requests: AiImageInput[] = [];
    setAiProviderForTests({
      ...unusedAiProvider,
      generateStickerImage: async (input) => {
        requests.push(input);
        return mock.generateStickerImage(input);
      },
      showSticker: async () => "Added gogogog! lettering.",
      editSticker: async (_input, session) => {
        if (placement === "add") {
          await session.addImageLayer({
            prompt: 'Comic lettering reading exactly "gogogog!", yellow-orange fill and dark outline',
            name: "gogogog!", x: 0.5, y: 0.25, scaleX: 0.4, scaleY: 0.4,
          });
        } else {
          await session.editImageLayer({ layerId: base.layers[0].id, prompt: 'Paint "gogogog!" onto the car' });
        }
        const result = await session.finalizeEdit();
        return { revision: result.revision, finalized: true };
      },
    });
    const edit = await createChatTurn(db, ownerId, sticker.stickerId, {
      text: "Add cartoon text to the sticker says gogogog!", intent: "edit", attachments: [],
      imagePlacement: placement, baseRevisionId: baseTurn.jobId,
    });
    expect((await stickerGenerationWorkflow(edit.jobId)).workflowStatus).toBe("succeeded");
    expect(requests).toHaveLength(1);
    const [row] = await db.select().from(stickerRevisions).where(eq(stickerRevisions.id, edit.jobId));
    const document = StickerDocumentSchema.parse(row.documentJson);
    if (placement === "add") {
      expect(requests[0]).toMatchObject({ mode: "generate", isolatedLayer: true });
      expect(requests[0].conversationContext).toBeUndefined();
      expect(document.layers).toHaveLength(2);
      expect(document.layers[0]).toEqual(base.layers[0]);
      expect(document.layers[1]).toMatchObject({ type: "image", name: "gogogog!" });
      expect(document.layers.some((layer) => layer.type === "text")).toBe(false);
    } else {
      expect(requests[0].mode).toBe("conversation_edit");
      expect(requests[0].references.length).toBeGreaterThan(0);
      expect(requests[0].conversationContext).toContain("red car");
      expect(document.layers).toHaveLength(1);
      expect(document.layers[0].id).toBe(base.layers[0].id);
    }
  } finally {
    await close();
  }
});
