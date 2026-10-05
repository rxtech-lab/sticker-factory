ALTER TABLE "user_pets" ADD COLUMN "identity_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "context_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "signals_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "signals_updated_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "life_id" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "life_run_id" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "life_tick_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "next_event_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "last_share_at" timestamp with time zone;
--> statement-breakpoint
CREATE TABLE "pet_events" (
  "id" text PRIMARY KEY,
  "user_id" text NOT NULL REFERENCES "users"("id") ON DELETE CASCADE,
  "life_id" text NOT NULL,
  "sticker_id" text,
  "kind" text NOT NULL,
  "title" text NOT NULL,
  "detail" text NOT NULL,
  "effects_json" jsonb NOT NULL,
  "stats_before_json" jsonb NOT NULL,
  "stats_after_json" jsonb NOT NULL,
  "signals_json" jsonb,
  "debug_json" jsonb NOT NULL,
  "created_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "pet_events_life_idx" ON "pet_events" ("user_id", "life_id", "created_at");
