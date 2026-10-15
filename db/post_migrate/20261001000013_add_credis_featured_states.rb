# frozen_string_literal: true

class AddCredisFeaturedStates < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_relation_revisions, :featured_tag_id, :bigint
    add_column :credis_event_outbox, :featured_tag_id, :bigint
    add_column :credis_event_outbox, :featured_post_id, :bigint
    add_column :credis_event_outbox, :featured_operator_user_id, :bigint

    # Retain the five-column identity FK: a nullable sixth key alone would
    # skip verification of every pre-Featured row under MATCH SIMPLE.
    remove_index :credis_relation_revisions, name: :idx_credis_relation_identity
    execute <<~SQL
      CREATE UNIQUE INDEX idx_credis_relation_identity ON credis_relation_revisions
      (relation_kind, actor_user_id, target_type, target_id, featured_tag_id) NULLS NOT DISTINCT;
      CREATE UNIQUE INDEX idx_credis_relation_id_and_featured_identity ON credis_relation_revisions
      (relation_revision_id, relation_kind, actor_user_id, target_type, target_id, featured_tag_id)
      NULLS NOT DISTINCT;
      CREATE UNIQUE INDEX idx_credis_featured_topic_tag ON credis_relation_revisions
      (target_type, target_id, featured_tag_id) WHERE relation_kind = 'featured';
      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_featured_identity_fk
      FOREIGN KEY (relation_revision_id, relation_kind, actor_user_id, target_type, target_id, featured_tag_id)
      REFERENCES credis_relation_revisions
      (relation_revision_id, relation_kind, actor_user_id, target_type, target_id, featured_tag_id)
      MATCH SIMPLE ON DELETE RESTRICT;
      ALTER TABLE credis_relation_revisions ADD CONSTRAINT credis_relation_featured_metadata_check
      CHECK (COALESCE((
        (relation_kind = 'featured' AND target_type = 'Topic' AND actor_user_id > 0
          AND target_id > 0 AND featured_tag_id > 0) OR
        (relation_kind <> 'featured' AND featured_tag_id IS NULL)
      ), FALSE));
      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_featured_metadata_check
      CHECK (COALESCE((
        (relation_kind = 'featured' AND target_type = 'Topic' AND actor_user_id > 0
          AND target_id > 0 AND featured_tag_id > 0 AND featured_post_id > 0
          AND (featured_operator_user_id > 0 OR featured_operator_user_id = -1)
          AND snapshot_schema_version = 2 AND target_author_user_id = actor_user_id
          AND target_post_version IS NOT NULL AND target_post_version >= 0
          AND target_content_status IN ('eligible', 'ineligible')
          AND target_deleted IS NOT NULL AND target_hidden IS NOT NULL AND target_user_deleted IS NOT NULL
          AND target_context->>'topic_id' = target_id::text
          AND target_context->>'post_number' = '1' AND target_context->>'post_type' = '1'
          AND ((origin = 'featured_added' AND to_state = 'active')
            OR (origin = 'featured_removed' AND to_state = 'inactive'))) OR
        (relation_kind <> 'featured' AND featured_tag_id IS NULL
          AND featured_post_id IS NULL AND featured_operator_user_id IS NULL)
      ), FALSE));
    SQL

    execute "ALTER TABLE credis_relation_revisions DROP CONSTRAINT credis_relation_kind_state_check"
    execute <<~SQL
      ALTER TABLE credis_relation_revisions ADD CONSTRAINT credis_relation_kind_state_check CHECK (
        (relation_kind = 'interaction' AND
          (state_code IN ('none', 'ordinary_like') OR state_code ~ '^reaction:.+$')) OR
        (relation_kind = 'bookmark' AND state_code IN ('inactive', 'active')) OR
        (relation_kind IN ('topic_first_post', 'reply') AND target_type = 'Post' AND actor_user_id > 0
          AND state_code IN ('unknown', 'inactive', 'active')) OR
        (relation_kind = 'solved' AND target_type = 'Post' AND actor_user_id > 0
          AND state_code IN ('inactive', 'active')) OR
        (relation_kind = 'featured' AND target_type = 'Topic' AND actor_user_id > 0
          AND state_code IN ('inactive', 'active'))
      )
    SQL
    execute "ALTER TABLE credis_event_outbox DROP CONSTRAINT credis_outbox_state_transition_check"
    execute <<~SQL
      ALTER TABLE credis_event_outbox ADD CONSTRAINT credis_outbox_state_transition_check CHECK (
        from_state <> to_state AND (
          (relation_kind = 'interaction' AND
            (from_state IN ('none', 'ordinary_like') OR from_state ~ '^reaction:.+$') AND
            (to_state IN ('none', 'ordinary_like') OR to_state ~ '^reaction:.+$')) OR
          (relation_kind = 'bookmark' AND
            from_state IN ('inactive', 'active') AND to_state IN ('inactive', 'active')) OR
          (relation_kind IN ('topic_first_post', 'reply') AND target_type = 'Post' AND actor_user_id > 0
            AND from_state IN ('unknown', 'inactive', 'active') AND to_state IN ('inactive', 'active')) OR
          (relation_kind = 'solved' AND target_type = 'Post' AND actor_user_id > 0
            AND from_state IN ('inactive', 'active') AND to_state IN ('inactive', 'active')) OR
          (relation_kind = 'featured' AND target_type = 'Topic' AND actor_user_id > 0
            AND from_state IN ('inactive', 'active') AND to_state IN ('inactive', 'active'))
        )
      )
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION credis_reject_relation_identity_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(NEW.relation_kind, NEW.actor_user_id, NEW.target_type, NEW.target_id, NEW.featured_tag_id)
          IS DISTINCT FROM ROW(OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id, OLD.featured_tag_id) THEN
          RAISE EXCEPTION 'credis_relation_revisions identity fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
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
          NEW.target_snapshot_captured_at, NEW.reaction_settings_digest, NEW.target_context,
          NEW.featured_tag_id, NEW.featured_post_id, NEW.featured_operator_user_id
        ) IS DISTINCT FROM ROW(
          OLD.outbox_id, OLD.event_uid, OLD.epoch_id, OLD.relation_revision_id,
          OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id,
          OLD.revision, OLD.operation_id, OLD.from_state, OLD.to_state,
          OLD.occurred_at, OLD.origin, OLD.created_at,
          OLD.snapshot_schema_version, OLD.target_author_user_id,
          OLD.target_post_version, OLD.target_content_status,
          OLD.target_deleted, OLD.target_hidden, OLD.target_user_deleted,
          OLD.target_snapshot_captured_at, OLD.reaction_settings_digest, OLD.target_context,
          OLD.featured_tag_id, OLD.featured_post_id, OLD.featured_operator_user_id
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
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Featured events and migrate forward"
  end
end
