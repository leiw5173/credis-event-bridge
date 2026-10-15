# frozen_string_literal: true

class AddCredisEventTopicContext < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_event_outbox, :target_context, :jsonb
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis event Topic context must be retained and migrated forward"
  end
end
