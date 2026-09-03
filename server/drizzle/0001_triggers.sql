-- Custom SQL migration file, put your code below! --

-- The invariants the schema itself cannot state, as PL/pgSQL triggers.
--
-- These are ports of the SQLite triggers in `drizzle/sqlite-legacy/`, kept deliberately literal:
-- the same firing conditions, the same abort messages (services and tests match on that text), and
-- the same division of labour — the service layer checks these too, and the trigger is the backstop
-- for anything that reaches the database another way.
--
-- Two SQLite quirks the port sheds rather than reproduces. Postgres fires row triggers for rows a
-- foreign-key `ON DELETE CASCADE` removes, so the install-counter drift `recomputePackCounters`
-- documents cannot happen here. And `IS NOT` becomes `IS DISTINCT FROM`, which is what the SQLite
-- spelling meant all along.

-- Assets may not be attached to a sticker that is already being deleted: the cleanup job has
-- already listed what it will remove, and a late attachment would leave an orphan in R2.
CREATE FUNCTION assets_reject_deleting_sticker() RETURNS trigger AS $$
BEGIN
  IF NEW.sticker_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM stickers s WHERE s.id = NEW.sticker_id AND s.status = 'deleting'
  ) THEN
    RAISE EXCEPTION 'cannot attach an asset to a deleting sticker';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER assets_reject_deleting_sticker_insert
BEFORE INSERT ON assets
FOR EACH ROW EXECUTE FUNCTION assets_reject_deleting_sticker();
--> statement-breakpoint

CREATE TRIGGER assets_reject_deleting_sticker_binding
BEFORE UPDATE OF sticker_id ON assets
FOR EACH ROW EXECUTE FUNCTION assets_reject_deleting_sticker();
--> statement-breakpoint

-- A revision is a permanent record of what was built. Its ancestry, its document, and every
-- rendition it points at are fixed at insert; only `candidate_state` and `decided_at` move
-- afterwards. The exception is a sticker on its way out, whose rows the cleanup job may unbind.
CREATE FUNCTION sticker_revisions_reject_core_update() RETURNS trigger AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM stickers s WHERE s.id = OLD.sticker_id AND s.status <> 'deleting')
    AND (
      NEW.parent_revision_id IS DISTINCT FROM OLD.parent_revision_id
      OR NEW.source_message_id IS DISTINCT FROM OLD.source_message_id
      OR NEW.kind IS DISTINCT FROM OLD.kind
      OR NEW.document_json IS DISTINCT FROM OLD.document_json
      OR NEW.master_asset_id IS DISTINCT FROM OLD.master_asset_id
      OR NEW.preview_asset_id IS DISTINCT FROM OLD.preview_asset_id
      OR NEW.png_asset_id IS DISTINCT FROM OLD.png_asset_id
      OR NEW.gif_asset_id IS DISTINCT FROM OLD.gif_asset_id
      OR NEW.apng_asset_id IS DISTINCT FROM OLD.apng_asset_id
      OR NEW.mp4_asset_id IS DISTINCT FROM OLD.mp4_asset_id
      OR NEW.system_asset_id IS DISTINCT FROM OLD.system_asset_id
      OR NEW.attachment_medium_asset_id IS DISTINCT FROM OLD.attachment_medium_asset_id
      OR NEW.attachment_small_asset_id IS DISTINCT FROM OLD.attachment_small_asset_id
    )
  THEN
    RAISE EXCEPTION 'sticker revision core fields are immutable';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

-- The `UPDATE OF` list names every column the body compares. A column added to the body without
-- being added here would simply never be checked.
CREATE TRIGGER sticker_revisions_core_immutable
BEFORE UPDATE OF
  parent_revision_id, source_message_id, kind, document_json, master_asset_id, preview_asset_id,
  png_asset_id, gif_asset_id, apng_asset_id, mp4_asset_id, system_asset_id,
  attachment_medium_asset_id, attachment_small_asset_id
ON sticker_revisions
FOR EACH ROW EXECUTE FUNCTION sticker_revisions_reject_core_update();
--> statement-breakpoint

-- `stickers.active_revision_id` carries no foreign key, because a revision cannot exist before the
-- sticker it belongs to and a circular constraint would make the first insert impossible. This is
-- what stands in for one: the pointer must name a revision of *this* sticker.
CREATE FUNCTION validate_sticker_active_revision() RETURNS trigger AS $$
BEGIN
  IF NEW.active_revision_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM sticker_revisions r
    WHERE r.id = NEW.active_revision_id AND r.sticker_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'active revision must belong to sticker';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER validate_sticker_active_revision_insert
BEFORE INSERT ON stickers
FOR EACH ROW EXECUTE FUNCTION validate_sticker_active_revision();
--> statement-breakpoint

CREATE TRIGGER validate_sticker_active_revision_update
BEFORE UPDATE OF active_revision_id ON stickers
FOR EACH ROW EXECUTE FUNCTION validate_sticker_active_revision();
--> statement-breakpoint

-- A pack may only contain stickers its creator owns. The service checks this too; the trigger is
-- the backstop, in the same style as `assets_reject_deleting_sticker`.
CREATE FUNCTION sticker_pack_items_require_creator_ownership() RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM stickers s
    JOIN sticker_packs p ON p.id = NEW.pack_id
    WHERE s.id = NEW.sticker_id AND s.owner_id = p.creator_id AND s.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'a pack may only contain stickers owned by its creator';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER sticker_pack_items_require_creator_ownership_insert
BEFORE INSERT ON sticker_pack_items
FOR EACH ROW EXECUTE FUNCTION sticker_pack_items_require_creator_ownership();
--> statement-breakpoint

-- Counter maintenance. Browse sorts by popularity and prints a count on every card, so these are
-- denormalized onto the pack rather than counted per row on read.
--
-- `install_count` is current installs and moves both ways; `install_total` is a lifetime tally and
-- only ever climbs.
CREATE FUNCTION pack_installs_count_insert() RETURNS trigger AS $$
BEGIN
  IF NEW.state = 'installed' THEN
    UPDATE sticker_packs
    SET install_count = install_count + 1, install_total = install_total + 1
    WHERE id = NEW.pack_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER pack_installs_count_insert
AFTER INSERT ON pack_installs
FOR EACH ROW EXECUTE FUNCTION pack_installs_count_insert();
--> statement-breakpoint

CREATE FUNCTION pack_installs_count_update() RETURNS trigger AS $$
BEGIN
  IF NEW.state IS DISTINCT FROM OLD.state THEN
    UPDATE sticker_packs SET
      install_count = install_count + (CASE WHEN NEW.state = 'installed' THEN 1 ELSE -1 END),
      install_total = install_total + (CASE WHEN NEW.state = 'installed' THEN 1 ELSE 0 END)
    WHERE id = NEW.pack_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER pack_installs_count_update
AFTER UPDATE OF state ON pack_installs
FOR EACH ROW EXECUTE FUNCTION pack_installs_count_update();
--> statement-breakpoint

CREATE FUNCTION pack_installs_count_delete() RETURNS trigger AS $$
BEGIN
  IF OLD.state = 'installed' THEN
    UPDATE sticker_packs SET install_count = install_count - 1 WHERE id = OLD.pack_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER pack_installs_count_delete
AFTER DELETE ON pack_installs
FOR EACH ROW EXECUTE FUNCTION pack_installs_count_delete();
--> statement-breakpoint

CREATE FUNCTION sticker_pack_items_count_insert() RETURNS trigger AS $$
BEGIN
  UPDATE sticker_packs
  SET item_count = item_count + 1, updated_at = NEW.added_at
  WHERE id = NEW.pack_id;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER sticker_pack_items_count_insert
AFTER INSERT ON sticker_pack_items
FOR EACH ROW EXECUTE FUNCTION sticker_pack_items_count_insert();
--> statement-breakpoint

CREATE FUNCTION sticker_pack_items_count_delete() RETURNS trigger AS $$
BEGIN
  UPDATE sticker_packs SET item_count = item_count - 1 WHERE id = OLD.pack_id;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
--> statement-breakpoint

CREATE TRIGGER sticker_pack_items_count_delete
AFTER DELETE ON sticker_pack_items
FOR EACH ROW EXECUTE FUNCTION sticker_pack_items_count_delete();
