import { auth } from "@/lib/auth/web";
import { isHealthyWebSession } from "@/lib/auth/session-health";

export { isHealthyWebSession } from "@/lib/auth/session-health";

export async function getHealthyWebSession() {
  if (process.env.NODE_ENV !== "production"
    && process.env.STICKER_FACTORY_E2E === "true"
    && process.env.STICKER_FACTORY_E2E_USER_ID) {
    return {
      user: {
        id: process.env.STICKER_FACTORY_E2E_USER_ID,
        name: "Playwright User",
        email: "playwright@example.test",
      },
      expires: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    };
  }
  const session = await auth();
  return isHealthyWebSession(session) ? session : null;
}
