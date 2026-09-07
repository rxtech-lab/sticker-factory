ALTER TABLE "generation_jobs" ADD COLUMN "app_clip" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "generation_jobs" ADD COLUMN "usage_reservation_id" text;
