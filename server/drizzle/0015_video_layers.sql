-- Generated video clips, for the motion keyframes cannot express.
--
-- A plan may now give one layer a `video` source: a short 1:1 clip animated from a still the build
-- separated from the approved reference, shot against a chroma backdrop, and keyed out on device.
-- Two things change in the database for it.
--
-- Video spend gets the same two columns image spend has: an exact USD audit total, and the sum of
-- per-clip points, each clip rounded up on its own (`lib/ai/cost.ts`). Kept apart from image spend
-- rather than folded into it so the settle metadata can say what a job was actually charged for.
--
-- `video` joins the asset kind enum. As in 0009 and 0010, the live database is managed by
-- `drizzle-kit push` and carries neither the CHECK constraint nor the triggers below; there the
-- whole migration is the two ADD COLUMNs. The rebuild is for databases built from these files —
-- the test database, and any fresh one. The same three things are load-bearing here as in 0008,
-- 0009 and 0010: the copy names its columns explicitly, `r2_key`'s UNIQUE is respelled, and both
-- `assets_reject_deleting_sticker_*` triggers are recreated verbatim. `PRAGMA legacy_alter_table`
-- keeps the rename from rewriting the foreign keys that point at `assets` from `plans`,
-- `creator_profiles`, and `sticker_revisions`.

ALTER TABLE generation_jobs ADD COLUMN api_video_cost_nanodollars integer NOT NULL DEFAULT 0;
ALTER TABLE generation_jobs ADD COLUMN api_video_points integer NOT NULL DEFAULT 0;

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
    'reference', 'mask', 'master', 'preview', 'apng', 'gif', 'mp4', 'system', 'chat_attachment',
    'sequence', 'attachment', 'video'
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
  sequence_columns INTEGER,
  sequence_rows INTEGER
);
INSERT INTO assets (
  id, owner_id, sticker_id, kind, state, r2_key, mime_type, byte_size, width, height,
  frame_count, duration_seconds, fps, sha256, has_alpha, original_filename, created_at, ready_at,
  sequence_columns, sequence_rows
)
SELECT
  id, owner_id, sticker_id, kind, state, r2_key, mime_type, byte_size, width, height,
  frame_count, duration_seconds, fps, sha256, has_alpha, original_filename, created_at, ready_at,
  sequence_columns, sequence_rows
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
