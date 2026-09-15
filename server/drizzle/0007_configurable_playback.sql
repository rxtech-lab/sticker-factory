ALTER TABLE "sticker_revisions" ADD COLUMN "playback_json" jsonb;
--> statement-breakpoint
ALTER TABLE "assets" DROP CONSTRAINT "assets_kind_check";
--> statement-breakpoint
ALTER TABLE "assets" ADD CONSTRAINT "assets_kind_check" CHECK ("kind" IN ('reference','mask','master','preview','apng','gif','mp4','system','chat_attachment','sequence','attachment','video','webp','messenger_whatsapp','messenger_telegram','playback'));

--> statement-breakpoint
CREATE FUNCTION sticker_revisions_reject_playback_update() RETURNS trigger AS $$
BEGIN
  IF NEW.playback_json IS DISTINCT FROM OLD.playback_json
    AND EXISTS (SELECT 1 FROM stickers WHERE id = OLD.sticker_id AND status <> 'deleting') THEN
    RAISE EXCEPTION 'sticker revision playback is immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint
CREATE TRIGGER sticker_revisions_playback_immutable BEFORE UPDATE OF playback_json ON sticker_revisions
FOR EACH ROW EXECUTE FUNCTION sticker_revisions_reject_playback_update();
