ALTER TABLE "stickers" ADD COLUMN "pose_preset" text;
--> statement-breakpoint
ALTER TABLE "stickers" ADD CONSTRAINT "stickers_pose_preset_check" CHECK ("pose_preset" IS NULL OR "pose_preset" IN ('low', 'medium', 'high', 'ultra'));
