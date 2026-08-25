PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY NOT NULL,
  email TEXT,
  display_name TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE stickers (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('static', 'animated')),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'published', 'deleting')),
  active_revision_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER
);
CREATE INDEX stickers_owner_updated_idx ON stickers(owner_id, updated_at);
CREATE INDEX stickers_owner_status_idx ON stickers(owner_id, status);

CREATE TABLE chat_threads (
  id TEXT PRIMARY KEY NOT NULL,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX chat_threads_sticker_unique ON chat_threads(sticker_id);
CREATE INDEX chat_threads_owner_idx ON chat_threads(owner_id);

CREATE TABLE generation_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  source_message_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'edit', 'animation', 'chat', 'export', 'cleanup')),
  prior_sticker_status TEXT CHECK (prior_sticker_status IN ('draft', 'published')),
  state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'waiting', 'succeeded', 'failed', 'cancelled')),
  workflow_run_id TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  error_code TEXT,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE INDEX generation_jobs_owner_created_idx ON generation_jobs(owner_id, created_at);
CREATE INDEX generation_jobs_sticker_state_idx ON generation_jobs(sticker_id, state);
CREATE UNIQUE INDEX generation_jobs_one_active_per_sticker
  ON generation_jobs(sticker_id) WHERE state IN ('queued', 'running', 'waiting');

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY NOT NULL,
  thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  kind TEXT NOT NULL CHECK (kind IN ('text', 'image', 'image_edit', 'animation', 'export', 'status')),
  content TEXT NOT NULL,
  target_layer_id TEXT,
  base_revision_id TEXT,
  image_placement TEXT NOT NULL DEFAULT 'replace' CHECK (image_placement IN ('replace', 'add')),
  sequence INTEGER NOT NULL,
  revision_id TEXT,
  job_id TEXT REFERENCES generation_jobs(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'complete' CHECK (status IN ('complete', 'streaming', 'failed')),
  created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX chat_messages_thread_sequence_unique ON chat_messages(thread_id, sequence);
CREATE INDEX chat_messages_thread_created_idx ON chat_messages(thread_id, created_at);

CREATE TABLE assets (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT REFERENCES stickers(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('reference', 'mask', 'master', 'preview', 'gif', 'mp4', 'system', 'chat_attachment')),
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
  ready_at INTEGER
);
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

CREATE TABLE sticker_revisions (
  id TEXT PRIMARY KEY NOT NULL,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  parent_revision_id TEXT REFERENCES sticker_revisions(id) ON DELETE SET NULL,
  source_message_id TEXT REFERENCES chat_messages(id) ON DELETE SET NULL,
  kind TEXT NOT NULL CHECK (kind IN ('static', 'animated')),
  candidate_state TEXT NOT NULL DEFAULT 'candidate' CHECK (candidate_state IN ('candidate', 'accepted', 'rejected', 'superseded')),
  document_json TEXT NOT NULL,
  master_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  preview_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  png_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  gif_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  mp4_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  system_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);
CREATE INDEX sticker_revisions_sticker_created_idx ON sticker_revisions(sticker_id, created_at);
CREATE INDEX sticker_revisions_parent_idx ON sticker_revisions(parent_revision_id);

CREATE TRIGGER sticker_revisions_core_immutable
BEFORE UPDATE OF parent_revision_id, source_message_id, kind, document_json, master_asset_id, preview_asset_id, png_asset_id, gif_asset_id, mp4_asset_id, system_asset_id
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
    OR NEW.mp4_asset_id IS NOT OLD.mp4_asset_id
    OR NEW.system_asset_id IS NOT OLD.system_asset_id
  )
BEGIN
  SELECT RAISE(ABORT, 'sticker revision core fields are immutable');
END;

CREATE TABLE chat_attachments (
  message_id TEXT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('reference', 'mask')),
  target_layer_id TEXT,
  position INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(message_id, asset_id)
);
CREATE INDEX chat_attachments_asset_idx ON chat_attachments(asset_id);

CREATE TABLE generation_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  job_id TEXT NOT NULL REFERENCES generation_jobs(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('queued', 'started', 'progress', 'document', 'candidate', 'waiting', 'completed', 'failed')),
  data_json TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX generation_events_job_id_idx ON generation_events(job_id, id);
CREATE INDEX generation_events_owner_id_idx ON generation_events(owner_id, id);

CREATE TABLE idempotency_keys (
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  operation TEXT NOT NULL,
  key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response_status INTEGER,
  response_json TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id, operation, key)
);
CREATE INDEX idempotency_keys_expiry_idx ON idempotency_keys(expires_at);

CREATE TRIGGER validate_sticker_active_revision_insert
BEFORE INSERT ON stickers
WHEN NEW.active_revision_id IS NOT NULL
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM sticker_revisions r WHERE r.id = NEW.active_revision_id AND r.sticker_id = NEW.id
  ) THEN RAISE(ABORT, 'active revision must belong to sticker') END;
END;

CREATE TRIGGER validate_sticker_active_revision_update
BEFORE UPDATE OF active_revision_id ON stickers
WHEN NEW.active_revision_id IS NOT NULL
BEGIN
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM sticker_revisions r WHERE r.id = NEW.active_revision_id AND r.sticker_id = NEW.id
  ) THEN RAISE(ABORT, 'active revision must belong to sticker') END;
END;
