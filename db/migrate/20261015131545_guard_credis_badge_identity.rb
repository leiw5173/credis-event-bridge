# frozen_string_literal: true

class GuardCredisBadgeIdentity < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      CREATE FUNCTION guard_credis_user_badge_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF ROW(NEW.id,NEW.user_id,NEW.badge_id,NEW.post_id,NEW.seq,NEW.granted_at,NEW.granted_by_id)
          IS DISTINCT FROM ROW(OLD.id,OLD.user_id,OLD.badge_id,OLD.post_id,OLD.seq,OLD.granted_at,OLD.granted_by_id)
          AND EXISTS(SELECT 1 FROM credis_relation_revisions
            WHERE relation_kind='badge' AND target_type='UserBadge' AND target_id=OLD.id) THEN
          RAISE EXCEPTION 'Captured Badge grant identity is immutable' USING ERRCODE='P0001';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER credis_user_badge_identity BEFORE UPDATE ON user_badges
        FOR EACH ROW EXECUTE FUNCTION guard_credis_user_badge_identity();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain captured Badge identities and migrate forward"
  end
end
