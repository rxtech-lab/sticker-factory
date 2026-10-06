-- The weather outside a room's window, drawn in the pet's style as sky pieces the app animates.
ALTER TABLE "pet_weather_art" ADD COLUMN "layer" text DEFAULT 'sticker' NOT NULL;
--> statement-breakpoint
ALTER TABLE "pet_weather_art" ADD CONSTRAINT "pet_weather_art_layer_check" CHECK ("pet_weather_art"."layer" IN ('sticker', 'window'));
--> statement-breakpoint
DROP INDEX "pet_weather_art_look_idx";
--> statement-breakpoint
CREATE UNIQUE INDEX "pet_weather_art_look_idx" ON "pet_weather_art" USING btree ("sticker_id","kind","is_day","layer");
