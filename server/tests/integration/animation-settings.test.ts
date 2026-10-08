import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import { GET, PATCH } from "@/app/api/v1/account/animation-settings/route";
import { GET as roomScene } from "@/app/api/v1/pet/rooms/scene/route";
import { setDatabaseForTests, type Database } from "@/lib/db/client";
import { users, stickers } from "@/lib/db/schema";
import { rememberSVGCapability, backgroundAnimationEngine } from "@/lib/services/animation-settings";
import { createSticker } from "@/lib/services/stickers";
import { CreateStickerRequestSchema } from "@/lib/contracts/api";
import { createTestDatabase } from "@/tests/helpers/database";
import { seedUser } from "@/tests/helpers/packs";
import { ApiError } from "@/lib/http/errors";
import { requireApiPrincipal } from "@/lib/auth/bearer";

vi.mock("@/lib/auth/bearer", async original => ({
  ...await original<typeof import("@/lib/auth/bearer")>(),
  requireApiPrincipal: vi.fn(async () => ({ sub: "owner", clientId: "test", scopes: [] })),
}));

describe("animation testing settings", () => {
  let db: Database, close: () => Promise<void>;
  const request = (engine: string) => new Request("http://localhost/api/v1/account/animation-settings", { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify({ engine }) });
  beforeEach(async () => {
    ({ db, close } = await createTestDatabase()); setDatabaseForTests(db); await seedUser(db, "owner");
  });
  afterEach(async () => { setDatabaseForTests(undefined); await close(); vi.clearAllMocks(); vi.unstubAllEnvs(); });
  it("defaults capable accounts to SVG and preserves an explicit Legacy preference", async () => {
    expect(await backgroundAnimationEngine(db, "owner")).toBe("legacy");
    await rememberSVGCapability(db, "owner");
    expect(await backgroundAnimationEngine(db, "owner")).toBe("svg");
    expect((await PATCH(request("legacy"))).status).toBe(200);
    await rememberSVGCapability(db, "owner");
    expect(await (await GET(new Request("http://localhost/api/v1/account/animation-settings"))).json()).toEqual({ engine: "legacy" });
    expect((await PATCH(request("other"))).status).toBe(400);
  });
  it("lets the ANIMATION_ENGINE flag override the account preference", async () => {
    vi.stubEnv("ANIMATION_ENGINE", "legacy");
    await rememberSVGCapability(db, "owner");
    expect(await backgroundAnimationEngine(db, "owner")).toBe("legacy");
    expect(await (await GET(new Request("http://localhost/api/v1/account/animation-settings"))).json()).toEqual({ engine: "legacy" });
    vi.stubEnv("ANIMATION_ENGINE", "svg");
    await PATCH(request("legacy"));
    expect(await backgroundAnimationEngine(db, "owner")).toBe("svg");
    expect((await db.select().from(users).where(eq(users.id, "owner")))[0].animationEngine).toBe("legacy");
  });
  it("never forces SVG on accounts whose clients cannot play it", async () => {
    vi.stubEnv("ANIMATION_ENGINE", "svg");
    expect(await backgroundAnimationEngine(db, "owner")).toBe("legacy");
  });
  it("changes only future projects", async () => {
    const project = await createSticker(db, "owner", CreateStickerRequestSchema.parse({ title: "Pet", prompt: "A small pet", kind: "animated", controllable: true, controllableEngine: "svg" }));
    await PATCH(request("legacy"));
    expect((await db.select().from(stickers).where(eq(stickers.id, project.stickerId)))[0].controllableEngine).toBe("svg");
    expect((await db.select().from(users).where(eq(users.id, "owner")))[0].animationEngine).toBe("legacy");
  });
  it("requires authentication and never serves another owner's scene", async () => {
    vi.mocked(requireApiPrincipal).mockRejectedValueOnce(new ApiError(401, "UNAUTHORIZED", "Sign in"));
    expect((await PATCH(request("svg"))).status).toBe(401);
    expect((await roomScene(new Request(`http://localhost/api/v1/pet/rooms/scene?id=${crypto.randomUUID()}`))).status).toBe(404);
  });
});
