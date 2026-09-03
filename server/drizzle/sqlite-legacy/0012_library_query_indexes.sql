-- Make the three ordered reads behind /api/v1/library/sections index-native.
--
-- Each former index stopped one column before the query's deterministic tie-breaker, which made
-- SQLite build a temporary B-tree after finding the candidate rows. The default own-sticker query
-- also needs status between owner and its ordering columns so filtering and ordering use one index.

DROP INDEX stickers_owner_updated_idx;
CREATE INDEX stickers_owner_updated_idx ON stickers(owner_id, updated_at, id);

DROP INDEX stickers_owner_status_idx;
CREATE INDEX stickers_owner_status_updated_idx ON stickers(owner_id, status, updated_at, id);

DROP INDEX sticker_pack_items_pack_position_idx;
CREATE INDEX sticker_pack_items_pack_position_idx
ON sticker_pack_items(pack_id, position, sticker_id);

DROP INDEX pack_installs_user_state_idx;
CREATE INDEX pack_installs_user_state_idx
ON pack_installs(user_id, state, position, installed_at, pack_id);
