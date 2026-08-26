import { eq } from "drizzle-orm";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import type { Database } from "@/lib/db/client";
import { users } from "@/lib/db/schema";

export async function ensureUser(db: Database, principal: ApiPrincipal): Promise<void> {
  const now = new Date();
  await db.insert(users).values({
    id: principal.sub,
    email: principal.email,
    displayName: principal.name,
    createdAt: now,
    updatedAt: now,
  }).onConflictDoUpdate({
    target: users.id,
    set: { email: principal.email, displayName: principal.name, updatedAt: now },
  });
}

export async function getUser(db: Database, id: string) {
  return db.select().from(users).where(eq(users.id, id)).get();
}
