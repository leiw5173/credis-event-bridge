# frozen_string_literal: true

class BindCredisReportEvents < ActiveRecord::Migration[8.0]
  # Run after the existing Post, Solved and Featured constraints on fresh DBs.
  def up
    add_column :credis_event_outbox, :report_evidence_id, :bigint
    add_column :credis_event_outbox, :report_post_id, :bigint
    add_foreign_key :credis_event_outbox, :credis_report_evidence, column: :report_evidence_id, on_delete: :restrict
    execute <<~SQL
      CREATE UNIQUE INDEX idx_credis_report_event_actor
      ON credis_event_outbox (report_evidence_id, actor_user_id) WHERE relation_kind='flag';
      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_report_metadata_check
      CHECK (COALESCE((
        (relation_kind='flag' AND target_type='Reviewable' AND actor_user_id>0 AND target_id>0
          AND report_evidence_id>0 AND report_post_id>0 AND snapshot_schema_version IS NULL
          AND target_author_user_id IS NULL AND target_post_version IS NULL
          AND target_content_status IS NULL AND target_deleted IS NULL AND target_hidden IS NULL
          AND target_user_deleted IS NULL AND target_snapshot_captured_at IS NULL
          AND reaction_settings_digest IS NULL AND target_context IS NULL
          AND origin IN ('flag_submitted','flag_withdrawn','reviewable_transition')) OR
        (relation_kind<>'flag' AND report_evidence_id IS NULL AND report_post_id IS NULL)
      ),FALSE));
      ALTER TABLE credis_relation_revisions DROP CONSTRAINT credis_relation_kind_state_check;
      ALTER TABLE credis_relation_revisions ADD CONSTRAINT credis_relation_kind_state_check CHECK (
        (relation_kind='interaction' AND (state_code IN ('none','ordinary_like') OR state_code ~ '^reaction:.+$')) OR
        (relation_kind='bookmark' AND state_code IN ('inactive','active')) OR
        (relation_kind IN ('topic_first_post','reply') AND target_type='Post' AND actor_user_id>0 AND state_code IN ('unknown','inactive','active')) OR
        (relation_kind='solved' AND target_type='Post' AND actor_user_id>0 AND state_code IN ('inactive','active')) OR
        (relation_kind='featured' AND target_type='Topic' AND actor_user_id>0 AND state_code IN ('inactive','active')) OR
        (relation_kind='flag' AND target_type='Reviewable' AND actor_user_id>0 AND target_id>0
          AND (state_code='unknown' OR state_code ~ '^observed:[1-9][0-9]*$'))
      );
      ALTER TABLE credis_event_outbox DROP CONSTRAINT credis_outbox_state_transition_check;
      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_state_transition_check CHECK (
        from_state<>to_state AND (
          (relation_kind='interaction' AND (from_state IN ('none','ordinary_like') OR from_state ~ '^reaction:.+$')
            AND (to_state IN ('none','ordinary_like') OR to_state ~ '^reaction:.+$')) OR
          (relation_kind='bookmark' AND from_state IN ('inactive','active') AND to_state IN ('inactive','active')) OR
          (relation_kind IN ('topic_first_post','reply') AND target_type='Post' AND actor_user_id>0
            AND from_state IN ('unknown','inactive','active') AND to_state IN ('inactive','active')) OR
          (relation_kind='solved' AND target_type='Post' AND actor_user_id>0
            AND from_state IN ('inactive','active') AND to_state IN ('inactive','active')) OR
          (relation_kind='featured' AND target_type='Topic' AND actor_user_id>0
            AND from_state IN ('inactive','active') AND to_state IN ('inactive','active')) OR
          (relation_kind='flag' AND target_type='Reviewable' AND actor_user_id>0 AND target_id>0
            AND (from_state='unknown' OR from_state ~ '^observed:[1-9][0-9]*$')
            AND to_state ~ '^observed:[1-9][0-9]*$')
        )
      );
    SQL
    execute CredisEventBridge::ReportEventAuthority::INSTALL_SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Report events and migrate forward"
  end
end
