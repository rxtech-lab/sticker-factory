ALTER TABLE "plans" ADD COLUMN "restored_from_id" text;--> statement-breakpoint
ALTER TABLE "plans" ADD CONSTRAINT "plans_restored_from_id_plans_id_fk" FOREIGN KEY ("restored_from_id") REFERENCES "public"."plans"("id") ON DELETE set null ON UPDATE no action;
