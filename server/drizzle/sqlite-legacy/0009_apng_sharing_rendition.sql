-- The sharing rendition becomes an APNG.
--
-- An animated sticker used to publish a GIF alongside its Messages rendition. GIF cost it twice:
-- one bit of transparency, so every soft edge hard-cut against whatever it was dropped onto, and a
-- full independent image per frame, which on a ping-ponged 4s document at 30 FPS is 240 complete
-- 1024² frames — routinely tens of megabytes, and past the upload ceiling entirely on dense lifted
-- photography, which is what `SHARING_APNG_DIMENSIONS` exists to walk down from. The client already
-- had an indexed, frame-differenced APNG encoder for the 500 KB Messages sticker; pointing the
-- sharing rendition at it too buys 8-bit alpha and a fraction of the bytes at the same palette
-- depth GIF was capped at anyway.
--
-- Everything here is additive, and deliberately so. The obvious shape for this change is a rename —
-- one sharing-rendition slot, renamed to match what now goes in it — and it is the wrong one:
--
--   * SQLite cannot drop a column that a foreign key still names. Turso refuses the rewrite with
--     `error in table sticker_revisions after drop column: unknown column "gif_asset_id" in foreign
--     key definition`, so the rename does not merely risk data, it does not execute.
--   * Revisions published before the switch point at real GIF bytes through `gif_asset_id`, and
--     that column is the only thing that resolves their artwork. Nothing writes it any more, but
--     `previewAssetIdSql` and `revisionHasPublishedExports` still read it, coalescing the new column
--     ahead of the old one.
--   * `apng` likewise joins the asset kind enum rather than replacing `gif`. Rewriting those rows'
--     `kind` would label a GIF as an APNG, and `PACK_SHARED_ASSET_KINDS` reads this column to decide
--     what a stranger may see — a wrong value there is worse than a stale one.
--
-- Note that the live database is managed by `drizzle-kit push` and carries neither the CHECK
-- constraints nor the triggers this file writes; there the whole migration is the one ADD COLUMN.
-- The rebuild below is for databases built from these files — the test database, and any fresh one.
--
-- SQLite cannot ALTER a CHECK constraint, so widening the kind enum means rebuilding `assets`. The
-- same three things are load-bearing as in `0008_sequence_assets.sql`: the copy names its columns
-- explicitly, `r2_key`'s UNIQUE is respelled, and both `assets_reject_deleting_sticker_*` triggers
-- are recreated verbatim. `PRAGMA legacy_alter_table = ON` keeps the rename from rewriting the
-- foreign keys that point at `assets` from `plans` and `creator_profiles`.

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
    'reference', 'mask', 'master', 'preview', 'apng', 'gif', 'mp4', 'system', 'chat_attachment', 'sequence'
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

ALTER TABLE sticker_revisions ADD COLUMN apng_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;

-- The immutability trigger names every export column in its `UPDATE OF` list and in its body, so a
-- column added without rewriting it would leave a published revision's sharing rendition editable —
-- the one thing this trigger exists to prevent. `gif_asset_id` stays in both lists: it is still the
-- sharing rendition of every revision published before this migration, and no less immutable for
-- being legacy.
DROP TRIGGER sticker_revisions_core_immutable;

CREATE TRIGGER sticker_revisions_core_immutable
BEFORE UPDATE OF parent_revision_id, source_message_id, kind, document_json, master_asset_id, preview_asset_id, png_asset_id, gif_asset_id, apng_asset_id, mp4_asset_id, system_asset_id
ON sticker_revisions
WHEN EXISTS (SELECT 1 FROM stickers s WHERE s.id = OLD.sticker_id AND s.status != 'deleting')
  AND (
    NEW.parent_revision_id IS NOT OLD.parent_revision_id
    OR NEW.source_message_id IS NOT OLD.source_message_id
    OR NEW.kind IS NOT OLD.kind
    OR NEW.document_json IS NOT OLD.document_json
    OR NEW.master_asset_id IS NOT OLD.master_asset_id
    OR NEW.preview_asset_id IS NOT OLD.preview_asset_id
    OR NEW.png_asset_id IS NOT OLD.png_asset_id
    OR NEW.gif_asset_id IS NOT OLD.gif_asset_id
    OR NEW.apng_asset_id IS NOT OLD.apng_asset_id
    OR NEW.mp4_asset_id IS NOT OLD.mp4_asset_id
    OR NEW.system_asset_id IS NOT OLD.system_asset_id
  )
BEGIN
  SELECT RAISE(ABORT, 'sticker revision core fields are immutable');
END;

PRAGMA foreign_keys = ON;
