# frozen_string_literal: true

class AddCredisPostLifecycleStates < ActiveRecord::Migration[8.0]
  # Constraint replacement runs after deployment under Core's DDL protection.
  def up
    execute "ALTER TABLE credis_relation_revisions DROP CONSTRAINT credis_relation_kind_state_check"
    execute <<~SQL
      ALTER TABLE credis_relation_revisions ADD CONSTRAINT credis_relation_kind_state_check CHECK (
        (relation_kind = 'interaction' AND
          (state_code IN ('none', 'ordinary_like') OR state_code ~ '^reaction:.+$')) OR
        (relation_kind = 'bookmark' AND state_code IN ('inactive', 'active')) OR
        (relation_kind IN ('topic_first_post', 'reply') AND target_type = 'Post' AND actor_user_id > 0
          AND state_code IN ('unknown', 'inactive', 'active'))
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
            AND from_state IN ('unknown', 'inactive', 'active') AND to_state IN ('inactive', 'active'))
        )
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable lifecycle events and migrate forward"
  end
end
