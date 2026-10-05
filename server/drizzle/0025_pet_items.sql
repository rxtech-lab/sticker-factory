ALTER TABLE "user_pets" ADD COLUMN "items_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "items_art_key" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "items_context_key" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "items_updated_at" timestamp;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "items_claimed_at" timestamp;
