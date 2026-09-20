ALTER TABLE "users" ADD COLUMN "last_billing_environment" text;
--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_last_billing_environment_check"
  CHECK ("last_billing_environment" IN ('sandbox', 'production'));
