CREATE TABLE "user_pets" (
  "user_id" text PRIMARY KEY REFERENCES "users"("id") ON DELETE CASCADE,
  "sticker_id" text NOT NULL REFERENCES "stickers"("id") ON DELETE CASCADE,
  "created_at" timestamp with time zone NOT NULL,
  "updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "user_pets_sticker_idx" ON "user_pets" ("sticker_id");
