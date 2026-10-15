# frozen_string_literal: true

class RetainCredisReportActorIdentity < ActiveRecord::Migration[8.0]
  def up
    %i[credis_relation_revisions credis_event_outbox].each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ADD COLUMN live_actor_user_id bigint GENERATED ALWAYS AS
          (CASE WHEN relation_kind='flag' THEN NULL ELSE actor_user_id END) STORED;
      SQL
      add_foreign_key table, :users, column: :live_actor_user_id, on_delete: :restrict
      remove_foreign_key table, :users, column: :actor_user_id
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain historical Report actor IDs and migrate forward"
  end
end
