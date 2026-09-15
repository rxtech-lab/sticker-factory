CREATE TABLE "generation_live_activities" (
  "activity_id" text PRIMARY KEY,
  "owner_id" text NOT NULL REFERENCES "users"("id") ON DELETE CASCADE,
  "job_id" text NOT NULL REFERENCES "generation_jobs"("id") ON DELETE CASCADE,
  "token" text NOT NULL,
  "environment" text NOT NULL CHECK ("environment" IN ('sandbox', 'production')),
  "expires_at" timestamp with time zone NOT NULL,
  "last_event_id" integer NOT NULL DEFAULT 0,
  "last_push_timestamp" integer NOT NULL DEFAULT 0
);
--> statement-breakpoint
CREATE INDEX "generation_live_activities_job_idx" ON "generation_live_activities" ("job_id");
