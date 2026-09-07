-- Custom SQL migration file, put your code below! --

-- The 512 px copies WhatsApp and Telegram accept, encoded on the phone when a sticker is added to
-- a pack.
--
-- Both nullable, and independently so: a sticker whose artwork fits WhatsApp's 500 KB animated
-- ceiling may still overshoot Telegram's 256 KB, and binding the one that worked is better than
-- refusing both. They stay null for every revision published before this migration, which is what
-- the client reads to gray a pack member out rather than offer a hand-off that would fail.
ALTER TABLE "sticker_revisions" ADD COLUMN "whatsapp_asset_id" text;--> statement-breakpoint
ALTER TABLE "sticker_revisions" ADD COLUMN "telegram_asset_id" text;--> statement-breakpoint
ALTER TABLE "sticker_revisions" ADD CONSTRAINT "sticker_revisions_whatsapp_asset_id_assets_id_fk" FOREIGN KEY ("whatsapp_asset_id") REFERENCES "public"."assets"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "sticker_revisions" ADD CONSTRAINT "sticker_revisions_telegram_asset_id_assets_id_fk" FOREIGN KEY ("telegram_asset_id") REFERENCES "public"."assets"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint

-- The emoji both messengers file a sticker under, on the sticker rather than the revision: it is a
-- label, not artwork, and re-editing the drawing is no reason to forget it.
ALTER TABLE "stickers" ADD COLUMN "messenger_emoji" text;--> statement-breakpoint

-- The two new asset kinds. Recreated rather than amended for the same reason `webp` was: a CHECK
-- constraint has no ALTER form, and both statements run inside the migration's transaction, so no
-- row is ever written against a dropped constraint.
ALTER TABLE "assets" DROP CONSTRAINT "assets_kind_check";--> statement-breakpoint
ALTER TABLE "assets" ADD CONSTRAINT "assets_kind_check" CHECK ("assets"."kind" IN ('reference', 'mask', 'master', 'preview', 'apng', 'gif', 'mp4', 'system', 'chat_attachment', 'sequence', 'attachment', 'video', 'webp', 'messenger_whatsapp', 'messenger_telegram'));
