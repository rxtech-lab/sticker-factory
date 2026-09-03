-- Smaller copies of the sharing rendition, so size becomes a send-time choice.
--
-- The export used to ask, once, at publish time: a Large/Medium/Small picker that baked one
-- dimension into the `system` rendition forever. That is the wrong moment to ask. How big a sticker
-- should arrive depends on the conversation it is going into, not on what the person happened to
-- pick the day they made it, and changing their mind meant re-publishing.
--
-- So the export stops asking and renders the sharing rendition three times — 618, 408 and 300 —
-- and WinkySticker picks between them on the way out. Large keeps its existing home
-- (`apng_asset_id` for an animated sticker, `png_asset_id` for a static one); only the two smaller
-- ones need somewhere to live.
--
-- None of the three goes through the 500 KB ladder. That ladder spends frame rate before it spends
-- pixels — 618@24 down to 300@4 — and it exists solely because `MSSticker` has a byte ceiling.
-- These are sent with `insertAttachment`, which has none, so all three carry the document's own
-- frame rate and full palette. `system_asset_id` is untouched and still the only rendition Apple's
-- ceiling governs.
--
-- `attachment` joins the asset kind enum rather than reusing `apng`: an attachment rendition can be
-- a still PNG (a static sticker's Medium and Small) as well as an animated one, and `apng`'s
-- validation rejects a single-frame file by design. As in `0009_apng_sharing_rendition.sql`, the
-- live database is managed by `drizzle-kit push` and carries neither the CHECK constraints nor the
-- triggers below; there the whole migration is the two ADD COLUMNs. The rebuild is for databases
-- built from these files — the test database, and any fresh one.
--
-- The same three things are load-bearing in the `assets` rebuild as in 0008 and 0009: the copy
-- names its columns explicitly, `r2_key`'s UNIQUE is respelled, and both
-- `assets_reject_deleting_sticker_*` triggers are recreated verbatim. `PRAGMA legacy_alter_table`
-- keeps the rename from rewriting the foreign keys that point at `assets` from `plans` and
-- `creator_profiles`.

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
    'sequence', 'attachment'
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

ALTER TABLE sticker_revisions ADD COLUMN attachment_medium_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;
ALTER TABLE sticker_revisions ADD COLUMN attachment_small_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;

-- The immutability trigger names every export column in its `UPDATE OF` list and in its body, so a
-- column added without rewriting it would leave a published revision's smaller renditions editable
-- — the one thing this trigger exists to prevent.
DROP TRIGGER sticker_revisions_core_immutable;

CREATE TRIGGER sticker_revisions_core_immutable
BEFORE UPDATE OF parent_revision_id, source_message_id, kind, document_json, master_asset_id, preview_asset_id, png_asset_id, gif_asset_id, apng_asset_id, mp4_asset_id, system_asset_id, attachment_medium_asset_id, attachment_small_asset_id
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
    OR NEW.attachment_medium_asset_id IS NOT OLD.attachment_medium_asset_id
    OR NEW.attachment_small_asset_id IS NOT OLD.attachment_small_asset_id
  )
BEGIN
  SELECT RAISE(ABORT, 'sticker revision core fields are immutable');
END;

PRAGMA foreign_keys = ON;
