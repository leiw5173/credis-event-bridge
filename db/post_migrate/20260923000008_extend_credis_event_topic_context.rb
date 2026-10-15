# frozen_string_literal: true

class ExtendCredisEventTopicContext < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      ALTER TABLE credis_event_outbox DROP CONSTRAINT credis_outbox_source_snapshot_check
    SQL
    execute <<~SQL
      ALTER TABLE credis_event_outbox
      ADD CONSTRAINT credis_outbox_source_snapshot_check CHECK (COALESCE((
        (
          snapshot_schema_version IS NULL AND target_context IS NULL AND
          target_author_user_id IS NULL AND target_post_version IS NULL AND
          target_content_status IS NULL AND target_deleted IS NULL AND
          target_hidden IS NULL AND target_user_deleted IS NULL AND
          target_snapshot_captured_at IS NULL AND reaction_settings_digest IS NULL
        ) OR (
          snapshot_schema_version IN (1, 2) AND
          (target_author_user_id IS NULL OR target_author_user_id > 0) AND
          (target_post_version IS NULL OR target_post_version >= 0) AND
          target_content_status IN ('eligible', 'ineligible', 'unknown') AND
          target_snapshot_captured_at IS NOT NULL AND
          reaction_settings_digest ~ '^[0-9a-f]{64}$' AND
          (
            (
              snapshot_schema_version = 1 AND target_context IS NULL AND
              (
                target_content_status = 'unknown' OR
                (target_content_status = 'eligible' AND
                  target_author_user_id IS NOT NULL AND target_post_version IS NOT NULL AND
                  target_deleted IS FALSE AND target_hidden IS FALSE AND
                  target_user_deleted IS FALSE) OR
                (target_content_status = 'ineligible' AND
                  (target_deleted IS TRUE OR target_hidden IS TRUE OR target_user_deleted IS TRUE))
              )
            ) OR (
              snapshot_schema_version = 2 AND
              (
                (target_content_status = 'unknown' AND target_context IS NULL) OR
                (
                  target_content_status IN ('eligible', 'ineligible') AND
                  target_author_user_id IS NOT NULL AND target_post_version IS NOT NULL AND
                  target_deleted IS NOT NULL AND target_hidden IS NOT NULL AND
                  target_user_deleted IS NOT NULL AND
                  jsonb_typeof(target_context) = 'object' AND
                  target_context ?& ARRAY[
                    'topic_id','post_number','post_type','topic_deleted','topic_visible',
                    'topic_archetype','category_id','category_read_restricted'
                  ] AND
                  target_context - ARRAY[
                    'topic_id','post_number','post_type','topic_deleted','topic_visible',
                    'topic_archetype','category_id','category_read_restricted'
                  ] = '{}'::jsonb AND
                  (target_context->>'topic_id') ~ '^[1-9][0-9]*$' AND
                  (target_context->>'post_number') ~ '^[1-9][0-9]*$' AND
                  (target_context->>'post_type') ~ '^[1-9][0-9]*$' AND
                  jsonb_typeof(target_context->'topic_deleted') = 'boolean' AND
                  jsonb_typeof(target_context->'topic_visible') = 'boolean' AND
                  nullif(target_context->>'topic_archetype','') IS NOT NULL AND
                  jsonb_typeof(target_context->'category_read_restricted') = 'boolean' AND
                  (jsonb_typeof(target_context->'category_id') = 'null' OR
                    (target_context->>'category_id') ~ '^[1-9][0-9]*$') AND
                  (
                    (target_content_status = 'eligible' AND
                      target_deleted IS FALSE AND target_hidden IS FALSE AND
                      target_user_deleted IS FALSE AND
                      target_context->>'topic_deleted' = 'false' AND
                      target_context->>'topic_visible' = 'true' AND
                      target_context->>'topic_archetype' = 'regular' AND
                      target_context->>'post_type' = '1' AND
                      (target_context->>'category_id') ~ '^[1-9][0-9]*$' AND
                      target_context->>'category_read_restricted' = 'false') OR
                    (target_content_status = 'ineligible' AND
                      (target_deleted IS TRUE OR target_hidden IS TRUE OR
                        target_user_deleted IS TRUE OR
                        target_context->>'topic_deleted' = 'true' OR
                        target_context->>'topic_visible' = 'false' OR
                        target_context->>'topic_archetype' <> 'regular' OR
                        target_context->>'post_type' <> '1' OR
                        target_context->>'category_read_restricted' = 'true'))
                  )
                )
              )
            )
          )
        )
      ), FALSE))
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
          NEW.target_snapshot_captured_at, NEW.reaction_settings_digest,
          NEW.target_context
        ) IS DISTINCT FROM ROW(
          OLD.outbox_id, OLD.event_uid, OLD.epoch_id, OLD.relation_revision_id,
          OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id,
          OLD.revision, OLD.operation_id, OLD.from_state, OLD.to_state,
          OLD.occurred_at, OLD.origin, OLD.created_at,
          OLD.snapshot_schema_version, OLD.target_author_user_id,
          OLD.target_post_version, OLD.target_content_status,
          OLD.target_deleted, OLD.target_hidden, OLD.target_user_deleted,
          OLD.target_snapshot_captured_at, OLD.reaction_settings_digest,
          OLD.target_context
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
          "Credis event Topic context must be retained and migrated forward"
  end
end
