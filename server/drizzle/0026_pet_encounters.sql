ALTER TABLE "user_pets" ADD COLUMN "illness_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "medicine" integer DEFAULT 0 NOT NULL;
--> statement-breakpoint
CREATE TABLE "pet_encounters" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"life_id" text NOT NULL,
	"date" text NOT NULL,
	"title" text NOT NULL,
	"prompt" text NOT NULL,
	"choices_json" jsonb NOT NULL,
	"state" text NOT NULL,
	"choice_id" text,
	"expires_at" timestamp with time zone NOT NULL,
	"resolved_at" timestamp with time zone,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "pet_encounters_state_check" CHECK ("pet_encounters"."state" IN ('open', 'resolved'))
);
--> statement-breakpoint
ALTER TABLE "pet_encounters" ADD CONSTRAINT "pet_encounters_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "pet_encounters_day_idx" ON "pet_encounters" ("user_id", "life_id", "date");
