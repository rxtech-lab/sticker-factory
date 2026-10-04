CREATE TABLE "pet_weather_art" (
	"id" text PRIMARY KEY NOT NULL,
	"revision_id" text NOT NULL,
	"kind" text NOT NULL,
	"is_day" boolean NOT NULL,
	"state" text NOT NULL,
	"r2_key" text,
	"claimed_at" timestamp with time zone NOT NULL,
	"ready_at" timestamp with time zone,
	CONSTRAINT "pet_weather_art_kind_check" CHECK ("kind" IN ('sunny', 'cloudy', 'rainy', 'snowy', 'stormy', 'foggy', 'windy')),
	CONSTRAINT "pet_weather_art_state_check" CHECK ("state" IN ('drawing', 'ready', 'failed'))
);
--> statement-breakpoint
ALTER TABLE "pet_weather_art" ADD CONSTRAINT "pet_weather_art_revision_id_sticker_revisions_id_fk" FOREIGN KEY ("revision_id") REFERENCES "public"."sticker_revisions"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "pet_weather_art_look_idx" ON "pet_weather_art" USING btree ("revision_id","kind","is_day");
