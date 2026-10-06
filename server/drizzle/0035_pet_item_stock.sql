-- The item shop restocks once a day in the owner's time zone, and food and tickets bought from it
-- are kept in the pet's bag to use later.
ALTER TABLE "user_pets" ADD COLUMN "items_date" text;
--> statement-breakpoint
ALTER TABLE "user_pets" ADD COLUMN "bag_json" jsonb DEFAULT '[]'::jsonb NOT NULL;
