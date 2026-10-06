-- Friends a pet makes on its own: a new controllable sticker its agent dreams up from the weather, where its
-- owner is, what it remembers and how it feels, built in the background and introduced to the owner once.
CREATE TABLE "pet_friends" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"life_id" text NOT NULL,
	"sticker_id" text,
	"name" text NOT NULL,
	"brief" text NOT NULL,
	"story" text NOT NULL,
	"greeting" text NOT NULL,
	"state" text NOT NULL,
	"plan_job_id" text,
	"compose_job_id" text,
	"error" text,
	"seen_at" timestamp with time zone,
	"created_at" timestamp with time zone NOT NULL,
	"finished_at" timestamp with time zone,
	CONSTRAINT "pet_friends_state_check" CHECK ("pet_friends"."state" IN ('planning', 'building', 'publishing', 'ready', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "pet_friends" ADD CONSTRAINT "pet_friends_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "pet_friends" ADD CONSTRAINT "pet_friends_sticker_id_stickers_id_fk" FOREIGN KEY ("sticker_id") REFERENCES "public"."stickers"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "pet_friends_user_idx" ON "pet_friends" ("user_id", "created_at");
--> statement-breakpoint
CREATE UNIQUE INDEX "pet_friends_active_idx" ON "pet_friends" ("user_id") WHERE "pet_friends"."state" IN ('planning', 'building', 'publishing');
