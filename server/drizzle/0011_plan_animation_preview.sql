ALTER TABLE "plans" ADD COLUMN "animation_preview_asset_id" text REFERENCES "assets"("id") ON DELETE SET NULL;
