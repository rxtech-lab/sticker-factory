CREATE TABLE "pet_rooms" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"title" text NOT NULL,
	"description" text NOT NULL,
	"effects_json" jsonb NOT NULL,
	"price" integer NOT NULL,
	"art_key" text NOT NULL,
	"state" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"purchased_at" timestamp with time zone,
	CONSTRAINT "pet_rooms_state_check" CHECK ("pet_rooms"."state" IN ('offered', 'owned')),
	CONSTRAINT "pet_rooms_price_check" CHECK ("pet_rooms"."price" >= 0)
);
--> statement-breakpoint
ALTER TABLE "pet_rooms" ADD CONSTRAINT "pet_rooms_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "pet_rooms_user_idx" ON "pet_rooms" ("user_id", "state", "created_at");
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "room_id" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD CONSTRAINT "user_pets_room_id_pet_rooms_id_fk" FOREIGN KEY ("room_id") REFERENCES "public"."pet_rooms"("id") ON DELETE set null ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "room_effect_date" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "rooms_offered_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "rooms_claimed_at" timestamp with time zone;
