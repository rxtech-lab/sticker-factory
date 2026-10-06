-- Where each room's drawing has a clock face and a weather board for the app to write on.
ALTER TABLE "pet_rooms" ADD COLUMN "fixtures_json" jsonb;
