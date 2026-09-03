-- Custom SQL migration file, put your code below! --

-- The optional WebP copy of the sharing rendition.
--
-- Nullable, and it stays null for every revision published before this migration and for every
-- client that cannot encode the format — iOS `ImageIO` reads WebP but does not write it, so an app
-- without a linked encoder publishes a complete sticker with this column empty and its `.image`
-- sends keep falling back to the APNG. Nothing reads this column expecting a value.
ALTER TABLE "sticker_revisions" ADD COLUMN "webp_asset_id" text;--> statement-breakpoint
ALTER TABLE "sticker_revisions" ADD CONSTRAINT "sticker_revisions_webp_asset_id_assets_id_fk" FOREIGN KEY ("webp_asset_id") REFERENCES "public"."assets"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint

-- `webp` joins the asset kinds. Recreated rather than amended because a CHECK constraint has no
-- ALTER form; the two statements run inside the migration's transaction, so no row is ever written
-- against a dropped constraint.
ALTER TABLE "assets" DROP CONSTRAINT "assets_kind_check";--> statement-breakpoint
ALTER TABLE "assets" ADD CONSTRAINT "assets_kind_check" CHECK ("assets"."kind" IN ('reference', 'mask', 'master', 'preview', 'apng', 'gif', 'mp4', 'system', 'chat_attachment', 'sequence', 'attachment', 'video', 'webp'));
