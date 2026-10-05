ALTER TABLE "user_pets" ADD COLUMN "status_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "status_updated_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "last_sent_sticker_id" text REFERENCES "stickers"("id") ON DELETE SET NULL;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "last_sent_at" timestamp with time zone;
