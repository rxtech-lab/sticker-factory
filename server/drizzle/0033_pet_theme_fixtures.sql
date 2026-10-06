-- Where each place's drawing has a clock, a weather board and a status board for the app to write on.
ALTER TABLE "pet_themes" ADD COLUMN "fixtures_json" jsonb;
