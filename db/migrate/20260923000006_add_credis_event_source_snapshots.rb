# frozen_string_literal: true

class AddCredisEventSourceSnapshots < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_event_outbox, :snapshot_schema_version, :integer
    add_column :credis_event_outbox, :target_author_user_id, :bigint
    add_column :credis_event_outbox, :target_post_version, :integer
    add_column :credis_event_outbox, :target_content_status, :string
    add_column :credis_event_outbox, :target_deleted, :boolean
    add_column :credis_event_outbox, :target_hidden, :boolean
    add_column :credis_event_outbox, :target_user_deleted, :boolean
    add_column :credis_event_outbox, :target_snapshot_captured_at, :datetime
    add_column :credis_event_outbox, :reaction_settings_digest, :string

    execute <<~SQL
      ALTER TABLE credis_event_outbox
      ADD CONSTRAINT credis_outbox_source_snapshot_check
      CHECK (
        (
          snapshot_schema_version IS NULL AND
          target_author_user_id IS NULL AND target_post_version IS NULL AND
          target_content_status IS NULL AND target_deleted IS NULL AND
          target_hidden IS NULL AND target_user_deleted IS NULL AND
          target_snapshot_captured_at IS NULL AND reaction_settings_digest IS NULL
        ) OR (
          snapshot_schema_version IS NOT NULL AND snapshot_schema_version = 1 AND
          (target_author_user_id IS NULL OR target_author_user_id > 0) AND
          (target_post_version IS NULL OR target_post_version >= 0) AND
          target_content_status IS NOT NULL AND
          target_content_status IN ('eligible', 'ineligible', 'unknown') AND
          target_snapshot_captured_at IS NOT NULL AND
          reaction_settings_digest IS NOT NULL AND
          reaction_settings_digest ~ '^[0-9a-f]{64}$' AND
          (
            target_content_status = 'unknown' OR
            (target_content_status = 'eligible' AND
              target_author_user_id IS NOT NULL AND target_post_version IS NOT NULL AND
              target_deleted IS FALSE AND target_hidden IS FALSE AND
              target_user_deleted IS FALSE) OR
            (target_content_status = 'ineligible' AND
              (target_deleted IS TRUE OR target_hidden IS TRUE OR target_user_deleted IS TRUE))
          )
        )
      )
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION credis_reject_outbox_business_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.outbox_id, NEW.event_uid, NEW.epoch_id, NEW.relation_revision_id,
          NEW.relation_kind, NEW.actor_user_id, NEW.target_type, NEW.target_id,
          NEW.revision, NEW.operation_id, NEW.from_state, NEW.to_state,
          NEW.occurred_at, NEW.origin, NEW.created_at,
          NEW.snapshot_schema_version, NEW.target_author_user_id,
          NEW.target_post_version, NEW.target_content_status,
          NEW.target_deleted, NEW.target_hidden, NEW.target_user_deleted,
          NEW.target_snapshot_captured_at, NEW.reaction_settings_digest
        ) IS DISTINCT FROM ROW(
          OLD.outbox_id, OLD.event_uid, OLD.epoch_id, OLD.relation_revision_id,
          OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id,
          OLD.revision, OLD.operation_id, OLD.from_state, OLD.to_state,
          OLD.occurred_at, OLD.origin, OLD.created_at,
          OLD.snapshot_schema_version, OLD.target_author_user_id,
          OLD.target_post_version, OLD.target_content_status,
          OLD.target_deleted, OLD.target_hidden, OLD.target_user_deleted,
          OLD.target_snapshot_captured_at, OLD.reaction_settings_digest
        ) THEN
          RAISE EXCEPTION 'credis_event_outbox business fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis source snapshots must be retained and migrated forward"
  end
end
