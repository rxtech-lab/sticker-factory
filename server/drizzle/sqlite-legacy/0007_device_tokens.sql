PRAGMA foreign_keys = ON;

-- Push targets, so the server can announce a finished turn to a user who left the app.
--
-- Generation runs here, not on the phone, and the client's event stream dies the moment iOS
-- suspends the app — which is exactly the case a "your sticker is ready" banner exists for. So the
-- ending is announced from the side that observes it.
--
-- The APNs device token is the primary key rather than `(user_id, token)`: a token identifies an
-- app install, and iOS hands the same one to whoever signs in on that device next. Keying on it
-- means re-registering after a switch of accounts *moves* the row instead of leaving the previous
-- owner holding a token that would push their notifications to someone else's phone.
--
-- `disabled_at` rather than a delete: APNs reports a token as gone (410 Unregistered, or
-- BadDeviceToken) long after the app was removed, and keeping the tombstone means a repeated
-- failure is recorded once instead of re-tried on every future turn. Registering again clears it.
CREATE TABLE device_tokens (
  token TEXT PRIMARY KEY NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform TEXT NOT NULL DEFAULT 'ios' CHECK (platform IN ('ios')),
  -- Which APNs host will accept it. A sandbox token is rejected by production and vice versa, and
  -- a debug build and a TestFlight build of the same app produce different ones.
  environment TEXT NOT NULL DEFAULT 'production' CHECK (environment IN ('sandbox', 'production')),
  bundle_id TEXT,
  app_version TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  disabled_at INTEGER,
  disabled_reason TEXT
);

-- The only read path: every live token for the owner of a job that just finished.
CREATE INDEX device_tokens_user_active_idx ON device_tokens(user_id, disabled_at);
