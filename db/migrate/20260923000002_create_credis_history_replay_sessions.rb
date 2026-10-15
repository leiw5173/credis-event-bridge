# frozen_string_literal: true

class CreateCredisHistoryReplaySessions < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_history_replay_sessions,
                 id: :uuid,
                 primary_key: :replay_session_id do |t|
      t.bigint :epoch_id, null: false
      t.datetime :from_occurred_at, null: false
      t.datetime :to_occurred_at, null: false
      t.integer :page_limit, null: false
      t.datetime :expires_at, null: false
      t.timestamps null: false
    end

    add_foreign_key :credis_history_replay_sessions,
                    :credis_capture_epochs,
                    column: :epoch_id,
                    primary_key: :epoch_id,
                    on_delete: :restrict
    add_index :credis_history_replay_sessions, :expires_at
    execute <<~SQL
      ALTER TABLE credis_history_replay_sessions
      ADD CONSTRAINT credis_history_replay_query_check
      CHECK (
        page_limit BETWEEN 1 AND 100 AND
        from_occurred_at <= to_occurred_at AND
        expires_at > created_at
      )
    SQL
    execute <<~SQL
      CREATE FUNCTION credis_reject_history_session_update()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'credis_history_replay_sessions are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql
    SQL
    execute <<~SQL
      CREATE TRIGGER credis_history_replay_session_immutable
      BEFORE UPDATE ON credis_history_replay_sessions
      FOR EACH ROW EXECUTE FUNCTION credis_reject_history_session_update()
    SQL

    create_table :credis_history_replay_memberships, id: false do |t|
      t.uuid :replay_session_id, null: false
      t.bigint :outbox_id, null: false
      t.bigint :position, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_foreign_key :credis_history_replay_memberships,
                    :credis_history_replay_sessions,
                    column: :replay_session_id,
                    primary_key: :replay_session_id,
                    on_delete: :cascade
    add_foreign_key :credis_history_replay_memberships,
                    :credis_event_outbox,
                    column: :outbox_id,
                    primary_key: :outbox_id,
                    on_delete: :restrict
    add_index :credis_history_replay_memberships,
              %i[replay_session_id position],
              unique: true,
              name: :idx_credis_history_replay_position
    add_index :credis_history_replay_memberships,
              %i[replay_session_id outbox_id],
              unique: true,
              name: :idx_credis_history_replay_event
    execute <<~SQL
      ALTER TABLE credis_history_replay_memberships
      ADD CONSTRAINT credis_history_replay_position_positive_check
      CHECK (position > 0)
    SQL
    execute <<~SQL
      CREATE FUNCTION credis_reject_history_membership_update()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'credis_history_replay_memberships are immutable'
          USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql
    SQL
    execute <<~SQL
      CREATE TRIGGER credis_history_replay_membership_immutable
      BEFORE UPDATE ON credis_history_replay_memberships
      FOR EACH ROW EXECUTE FUNCTION credis_reject_history_membership_update()
    SQL
  end

  def down
    drop_table :credis_history_replay_memberships
    drop_table :credis_history_replay_sessions
    execute "DROP FUNCTION credis_reject_history_membership_update()"
    execute "DROP FUNCTION credis_reject_history_session_update()"
  end
end
