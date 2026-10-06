CREATE TABLE "pet_themes" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"title" text NOT NULL,
	"description" text NOT NULL,
	"category" text NOT NULL,
	"effects_json" jsonb NOT NULL,
	"rules_json" jsonb NOT NULL,
	"art_key" text NOT NULL,
	"state" text NOT NULL,
	"expires_at" timestamp with time zone,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "pet_themes_state_check" CHECK ("pet_themes"."state" IN ('available', 'expired')),
	CONSTRAINT "pet_themes_category_check" CHECK ("pet_themes"."category" IN ('indoor', 'outdoor', 'restaurant', 'nature', 'travel', 'event', 'accident'))
);
--> statement-breakpoint
ALTER TABLE "pet_themes" ADD CONSTRAINT "pet_themes_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "pet_themes_user_idx" ON "pet_themes" ("user_id", "state", "created_at");
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "theme_id" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD CONSTRAINT "user_pets_theme_id_pet_themes_id_fk" FOREIGN KEY ("theme_id") REFERENCES "public"."pet_themes"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "theme_usage_json" jsonb;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "themes_discovered_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "themes_claimed_at" timestamp with time zone;
