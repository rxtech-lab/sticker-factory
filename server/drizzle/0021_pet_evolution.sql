ALTER TABLE "generation_jobs" ADD COLUMN "origin" text DEFAULT 'user' NOT NULL;
--> statement-breakpoint
ALTER TABLE "generation_jobs" ADD CONSTRAINT "generation_jobs_origin_check" CHECK ("origin" IN ('user', 'pet'));
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "evolution_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "last_evolved_at" timestamp with time zone;
