-- Captured footage becomes an asset kind of its own.
--
-- A `sequence` asset is one transparent PNG holding a grid of frames lifted from a Live Photo — a
-- sprite sheet. It needs its own kind rather than riding on `reference` for two reasons: the
-- reference rules explicitly reject anything a document would play back, and a sequence is the one
-- asset kind whose `frame_count`/`fps` are declared by the client at upload time instead of being
-- read back out of the file. It is also deliberately excluded from `PACK_SHARED_ASSET_KINDS`, since
-- this is the user's own face and must never become marketplace-visible.
--
-- The rebuild also adds `sequence_columns`/`sequence_rows`. The existing `frame_count`/`fps` say how
-- many frames there are and how fast they play; only the grid says where each one *is*, and the
-- image cannot say — a sprite sheet is indistinguishable from any other still. The document's layer
-- carries the grid too, but the planner authors documents server-side and has to read it from
-- somewhere.
--
-- SQLite cannot ALTER a CHECK constraint, so widening the enum means rebuilding the table. Three
-- things about that rebuild are load-bearing:
--   * the copy names its columns explicitly rather than using `SELECT *`, both because the new
--     table is wider than the old one and because a positional copy is how this kind of migration
--     silently shifts every value one column to the left;
--   * `r2_key`'s UNIQUE has to be respelled, or duplicate objects become possible; and
--   * both `assets_reject_deleting_sticker_*` triggers are dropped along with the table and must be
--     recreated verbatim, or assets can be attached to a sticker that is being purged.
-- `PRAGMA legacy_alter_table = ON` keeps the rename from rewriting the foreign keys that point at
-- `assets` from `plans` and `creator_profiles`.

PRAGMA foreign_keys = OFF;
PRAGMA legacy_alter_table = ON;

ALTER TABLE assets RENAME TO assets_old;
DROP INDEX IF EXISTS assets_owner_created_idx;
DROP INDEX IF EXISTS assets_sticker_kind_idx;

CREATE TABLE assets (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT REFERENCES stickers(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN (
    'reference', 'mask', 'master', 'preview', 'gif', 'mp4', 'system', 'chat_attachment', 'sequence'
  )),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'ready', 'failed', 'deleted')),
  r2_key TEXT NOT NULL UNIQUE,
  mime_type TEXT NOT NULL,
  byte_size INTEGER,
  width INTEGER,
  height INTEGER,
  frame_count INTEGER,
  duration_seconds REAL,
  fps REAL,
  sha256 TEXT,
  has_alpha INTEGER,
  original_filename TEXT,
  created_at INTEGER NOT NULL,
  ready_at INTEGER,
  -- Appended, and null for every kind but `sequence`.
  sequence_columns INTEGER,
  sequence_rows INTEGER
);
INSERT INTO assets (
  id, owner_id, sticker_id, kind, state, r2_key, mime_type, byte_size, width, height,
  frame_count, duration_seconds, fps, sha256, has_alpha, original_filename, created_at, ready_at
)
SELECT
  id, owner_id, sticker_id, kind, state, r2_key, mime_type, byte_size, width, height,
  frame_count, duration_seconds, fps, sha256, has_alpha, original_filename, created_at, ready_at
FROM assets_old;
DROP TABLE assets_old;

CREATE INDEX assets_owner_created_idx ON assets(owner_id, created_at);
CREATE INDEX assets_sticker_kind_idx ON assets(sticker_id, kind);

CREATE TRIGGER assets_reject_deleting_sticker_insert
BEFORE INSERT ON assets
WHEN NEW.sticker_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM stickers s WHERE s.id = NEW.sticker_id AND s.status = 'deleting')
BEGIN
  SELECT RAISE(ABORT, 'cannot attach an asset to a deleting sticker');
END;

CREATE TRIGGER assets_reject_deleting_sticker_binding
BEFORE UPDATE OF sticker_id ON assets
WHEN NEW.sticker_id IS NOT NULL
  AND EXISTS (SELECT 1 FROM stickers s WHERE s.id = NEW.sticker_id AND s.status = 'deleting')
BEGIN
  SELECT RAISE(ABORT, 'cannot attach an asset to a deleting sticker');
END;

PRAGMA legacy_alter_table = OFF;
PRAGMA foreign_keys = ON;
