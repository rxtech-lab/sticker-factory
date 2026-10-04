ALTER TABLE "pet_weather_art" ADD COLUMN "sticker_id" text;
--> statement-breakpoint
UPDATE "pet_weather_art" AS "art" SET "sticker_id" = "revision"."sticker_id" FROM "sticker_revisions" AS "revision" WHERE "revision"."id" = "art"."revision_id";
--> statement-breakpoint
DELETE FROM "pet_weather_art" WHERE "sticker_id" IS NULL OR "id" IN (
	SELECT "id" FROM (
		SELECT "id", row_number() OVER (PARTITION BY "sticker_id", "kind", "is_day" ORDER BY ("state" = 'ready') DESC, "claimed_at" DESC) AS "rank"
		FROM "pet_weather_art"
	) AS "ranked" WHERE "rank" > 1
);
--> statement-breakpoint
ALTER TABLE "pet_weather_art" ALTER COLUMN "sticker_id" SET NOT NULL;
--> statement-breakpoint
ALTER TABLE "pet_weather_art" ADD CONSTRAINT "pet_weather_art_sticker_id_stickers_id_fk" FOREIGN KEY ("sticker_id") REFERENCES "public"."stickers"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
DROP INDEX "pet_weather_art_look_idx";
--> statement-breakpoint
CREATE UNIQUE INDEX "pet_weather_art_look_idx" ON "pet_weather_art" USING btree ("sticker_id","kind","is_day");
