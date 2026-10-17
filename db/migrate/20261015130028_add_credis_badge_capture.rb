# frozen_string_literal: true

class AddCredisBadgeCapture < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_event_outbox, :badge_snapshot, :jsonb

    execute <<~SQL
      DO $extend$
      DECLARE definition text;
      BEGIN
        SELECT pg_get_expr(conbin, conrelid) INTO STRICT definition FROM pg_constraint
          WHERE conrelid='credis_relation_revisions'::regclass AND conname='credis_relation_kind_state_check';
        ALTER TABLE credis_relation_revisions DROP CONSTRAINT credis_relation_kind_state_check;
        EXECUTE 'ALTER TABLE credis_relation_revisions ADD CONSTRAINT credis_relation_kind_state_check CHECK (('
          || definition || ') OR (relation_kind=''badge'' AND target_type=''UserBadge'' AND actor_user_id>0 AND target_id>0 AND state_code IN (''inactive'',''active'')))';
        SELECT pg_get_expr(conbin, conrelid) INTO STRICT definition FROM pg_constraint
          WHERE conrelid='credis_event_outbox'::regclass AND conname='credis_outbox_state_transition_check';
        ALTER TABLE credis_event_outbox DROP CONSTRAINT credis_outbox_state_transition_check;
        EXECUTE 'ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_state_transition_check CHECK (('
          || definition || ') OR (relation_kind=''badge'' AND target_type=''UserBadge'' AND actor_user_id>0 AND target_id>0 AND ((from_state=''inactive'' AND to_state=''active'' AND origin=''badge_granted'') OR (from_state=''active'' AND to_state=''inactive'' AND origin=''badge_revoked''))))';
      END $extend$;

      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_badge_snapshot_presence CHECK (
        (relation_kind='badge' AND badge_snapshot IS NOT NULL AND jsonb_typeof(badge_snapshot)='object' AND snapshot_schema_version IS NULL)
        OR (relation_kind<>'badge' AND badge_snapshot IS NULL)
      );
      CREATE FUNCTION credis_reject_badge_snapshot_update() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.badge_snapshot IS DISTINCT FROM OLD.badge_snapshot THEN
          RAISE EXCEPTION 'Badge source snapshot is immutable' USING ERRCODE='P0001';
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER credis_badge_snapshot_immutable BEFORE UPDATE ON credis_event_outbox
        FOR EACH ROW EXECUTE FUNCTION credis_reject_badge_snapshot_update();

      CREATE FUNCTION capture_credis_user_badge() RETURNS trigger LANGUAGE plpgsql AS $capture$
      DECLARE source_row record; capture_epoch bigint; relation_id bigint; next_revision bigint;
        previous_state text; desired_state text; fact jsonb;
      BEGIN
        IF TG_OP='INSERT' THEN source_row:=NEW; desired_state:='active';
        ELSE source_row:=OLD; desired_state:='inactive'; END IF;
        IF source_row.user_id<=0 THEN RETURN NULL; END IF;
        PERFORM pg_advisory_xact_lock_shared(hashtextextended('credis-event-bridge:capture-epoch',0));
        SELECT epoch_id INTO capture_epoch FROM credis_capture_epochs
          WHERE status='collecting' AND baseline_complete
          AND baseline_manifest->'source_scope'->'target_types'->'badge' @> '["UserBadge"]'::jsonb
          FOR SHARE;
        IF capture_epoch IS NULL THEN RETURN NULL; END IF;
        INSERT INTO credis_relation_revisions(relation_kind,actor_user_id,target_type,target_id,state_code,revision,created_at,updated_at)
          VALUES('badge',source_row.user_id,'UserBadge',source_row.id,
            CASE WHEN TG_OP='DELETE' THEN 'active' ELSE 'inactive' END,0,clock_timestamp(),clock_timestamp())
          ON CONFLICT DO NOTHING;
        SELECT relation_revision_id,state_code,revision+1 INTO STRICT relation_id,previous_state,next_revision
          FROM credis_relation_revisions WHERE relation_kind='badge' AND actor_user_id=source_row.user_id
            AND target_type='UserBadge' AND target_id=source_row.id FOR UPDATE;
        IF previous_state=desired_state THEN RETURN NULL; END IF;
        fact:=jsonb_build_object('schema_version',1,'user_badge_id',source_row.id,'badge_id',source_row.badge_id,
          'user_id',source_row.user_id,'post_id',source_row.post_id,'seq',source_row.seq,
          'granted_at',to_char(source_row.granted_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
          'granted_by_id',source_row.granted_by_id);
        UPDATE credis_relation_revisions SET state_code=desired_state,revision=next_revision,updated_at=clock_timestamp()
          WHERE relation_revision_id=relation_id;
        INSERT INTO credis_event_outbox(event_uid,epoch_id,relation_revision_id,relation_kind,actor_user_id,target_type,target_id,
          revision,operation_id,from_state,to_state,occurred_at,origin,badge_snapshot,created_at,updated_at)
          VALUES(gen_random_uuid(),capture_epoch,relation_id,'badge',source_row.user_id,'UserBadge',source_row.id,
            next_revision,gen_random_uuid(),previous_state,desired_state,clock_timestamp(),
            CASE WHEN TG_OP='INSERT' THEN 'badge_granted' ELSE 'badge_revoked' END,fact,clock_timestamp(),clock_timestamp());
        RETURN NULL;
      END $capture$;
      CREATE TRIGGER credis_user_badge_capture AFTER INSERT OR DELETE ON user_badges
        FOR EACH ROW EXECUTE FUNCTION capture_credis_user_badge();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain Badge source history and migrate forward"
  end
end
