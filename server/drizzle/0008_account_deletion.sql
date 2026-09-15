ALTER TABLE "users" ADD COLUMN "deletion_scheduled_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "deletion_requested_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "deletion_request_id" text;
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "deleted_at" timestamp with time zone;
--> statement-breakpoint
CREATE INDEX "users_deletion_scheduled_at_idx" ON "users" USING btree ("deletion_scheduled_at");
