PRAGMA foreign_keys = ON;

-- Sticker packs: the marketplace layer over the single-owner sticker model.
--
-- Everything here is additive. No existing CHECK constraint is widened, so unlike 0004 and 0005
-- this migration needs no table rebuild.

-- The creator's public identity.
--
-- Deliberately separate from `users`: OAuth owns account profile data while a chosen public
-- marketplace name is durable application state. The handle is also the only creator
-- identifier that ever appears in a URL or a response body — the OAuth `sub` (which is
-- `users.id`, and every `owner_id` in this schema) must never be exposed.
CREATE TABLE creator_profiles (
  user_id TEXT PRIMARY KEY NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  handle TEXT NOT NULL,
  display_name TEXT,
  bio TEXT,
  avatar_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  -- Monetization placeholders. Nothing reads or writes these yet.
  payout_status TEXT NOT NULL DEFAULT 'none' CHECK (payout_status IN ('none', 'pending', 'active')),
  payout_provider TEXT,
  payout_account_ref TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX creator_profiles_handle_unique ON creator_profiles(handle);

-- `install_count` is what the UI shows ("N installs") and tracks current installs.
-- `install_total` is lifetime and never decremented, so a future "used by N people" figure
-- survives churn. Both are denormalized and trigger-maintained: browse sorts by popularity and
-- renders a count on every card, and a correlated COUNT per row would turn a 30-pack page into 30
-- extra scans on a single-region database — the same reasoning documented on
-- `selectStickerSummaries` in lib/services/stickers.ts.
CREATE TABLE sticker_packs (
  id TEXT PRIMARY KEY NOT NULL,
  creator_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug TEXT NOT NULL,
  title TEXT NOT NULL,
  summary TEXT,
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'published', 'unlisted', 'removed')),
  cover_sticker_id TEXT REFERENCES stickers(id) ON DELETE SET NULL,
  item_count INTEGER NOT NULL DEFAULT 0,
  install_count INTEGER NOT NULL DEFAULT 0,
  install_total INTEGER NOT NULL DEFAULT 0,
  -- Monetization placeholders. Every pack is free today; nothing charges.
  monetization TEXT NOT NULL DEFAULT 'free' CHECK (monetization IN ('free', 'paid', 'subscription')),
  price_cents INTEGER NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
  currency TEXT NOT NULL DEFAULT 'USD',
  revenue_share_bps INTEGER NOT NULL DEFAULT 0 CHECK (revenue_share_bps BETWEEN 0 AND 10000),
  published_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX sticker_packs_slug_unique ON sticker_packs(slug);
CREATE INDEX sticker_packs_creator_updated_idx ON sticker_packs(creator_id, updated_at);
CREATE INDEX sticker_packs_state_published_idx ON sticker_packs(state, published_at);
CREATE INDEX sticker_packs_state_installs_idx ON sticker_packs(state, install_count);

-- `ON DELETE CASCADE` on sticker_id means a hard-deleted sticker leaves its packs automatically.
-- During the soft-delete window (status 'deleting', deleted_at set) the row survives and the
-- resolution query's predicates hide it.
CREATE TABLE sticker_pack_items (
  pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  position INTEGER NOT NULL DEFAULT 0,
  added_at INTEGER NOT NULL,
  PRIMARY KEY(pack_id, sticker_id)
);
CREATE INDEX sticker_pack_items_pack_position_idx ON sticker_pack_items(pack_id, position);
CREATE INDEX sticker_pack_items_sticker_idx ON sticker_pack_items(sticker_id);

-- A pack may only contain stickers its creator owns. The service checks this too; the trigger is
-- the backstop, in the same style as `assets_reject_deleting_sticker_insert`.
CREATE TRIGGER sticker_pack_items_require_creator_ownership_insert
BEFORE INSERT ON sticker_pack_items
WHEN NOT EXISTS (
  SELECT 1 FROM stickers s
  JOIN sticker_packs p ON p.id = NEW.pack_id
  WHERE s.id = NEW.sticker_id AND s.owner_id = p.creator_id AND s.deleted_at IS NULL
)
BEGIN
  SELECT RAISE(ABORT, 'a pack may only contain stickers owned by its creator');
END;

-- Uninstall flips `state`, it never deletes the row. That keeps uninstall/reinstall idempotent
-- and preserves the (future) entitlement, so a user who paid and later removed a pack does not
-- pay twice.
CREATE TABLE pack_installs (
  pack_id TEXT NOT NULL REFERENCES sticker_packs(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  state TEXT NOT NULL DEFAULT 'installed' CHECK (state IN ('installed', 'uninstalled')),
  position INTEGER NOT NULL DEFAULT 0,
  -- Entitlement placeholders. Every acquisition is 'free' today.
  acquisition TEXT NOT NULL DEFAULT 'free' CHECK (acquisition IN ('free', 'purchase', 'gift', 'promo')),
  price_cents_paid INTEGER NOT NULL DEFAULT 0,
  order_ref TEXT,
  installed_at INTEGER NOT NULL,
  uninstalled_at INTEGER,
  PRIMARY KEY(pack_id, user_id)
);
CREATE INDEX pack_installs_user_state_idx ON pack_installs(user_id, state, position);
CREATE INDEX pack_installs_pack_state_idx ON pack_installs(pack_id, state);

-- Counter maintenance.
--
-- Known drift: SQLite does not fire row triggers for rows removed by a foreign-key ON DELETE
-- CASCADE unless PRAGMA recursive_triggers is on. Deleting a pack cascades its installs, but the
-- pack row is gone so its counter is moot. Deleting a *user* would cascade their installs and
-- leave other packs' install_count high. No code path hard-deletes users today, and
-- `recomputePackCounters` in lib/services/packs.ts (plus `bun run db:packs:recount`) reconciles
-- if one ever does.
CREATE TRIGGER pack_installs_count_insert
AFTER INSERT ON pack_installs
WHEN NEW.state = 'installed'
BEGIN
  UPDATE sticker_packs
  SET install_count = install_count + 1, install_total = install_total + 1
  WHERE id = NEW.pack_id;
END;

CREATE TRIGGER pack_installs_count_update
AFTER UPDATE OF state ON pack_installs
WHEN NEW.state IS NOT OLD.state
BEGIN
  UPDATE sticker_packs SET
    install_count = install_count + (CASE WHEN NEW.state = 'installed' THEN 1 ELSE -1 END),
    install_total = install_total + (CASE WHEN NEW.state = 'installed' THEN 1 ELSE 0 END)
  WHERE id = NEW.pack_id;
END;

CREATE TRIGGER pack_installs_count_delete
AFTER DELETE ON pack_installs
WHEN OLD.state = 'installed'
BEGIN
  UPDATE sticker_packs SET install_count = install_count - 1 WHERE id = OLD.pack_id;
END;

CREATE TRIGGER sticker_pack_items_count_insert
AFTER INSERT ON sticker_pack_items
BEGIN
  UPDATE sticker_packs
  SET item_count = item_count + 1, updated_at = NEW.added_at
  WHERE id = NEW.pack_id;
END;

CREATE TRIGGER sticker_pack_items_count_delete
AFTER DELETE ON sticker_pack_items
BEGIN
  UPDATE sticker_packs SET item_count = item_count - 1 WHERE id = OLD.pack_id;
END;
