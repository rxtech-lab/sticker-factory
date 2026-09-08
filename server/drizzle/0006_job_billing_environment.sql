ALTER TABLE "generation_jobs" ADD COLUMN "billing_environment" text;
--> statement-breakpoint
ALTER TABLE "generation_jobs" ADD CONSTRAINT "generation_jobs_billing_environment_check"
  CHECK ("billing_environment" IN ('xcode', 'sandbox', 'production'));
