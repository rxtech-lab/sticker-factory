ALTER TABLE users ADD COLUMN animation_engine text CHECK (animation_engine IN ('legacy', 'svg'));
--> statement-breakpoint
ALTER TABLE stickers ADD COLUMN controllable_engine text NOT NULL DEFAULT 'legacy' CHECK (controllable_engine IN ('legacy', 'svg'));
--> statement-breakpoint
ALTER TABLE generation_jobs ADD COLUMN controllable_engine text NOT NULL DEFAULT 'legacy' CHECK (controllable_engine IN ('legacy', 'svg'));
--> statement-breakpoint
ALTER TABLE pet_rooms ADD COLUMN scene_json jsonb;
--> statement-breakpoint
ALTER TABLE pet_themes ADD COLUMN scene_json jsonb;
