# frozen_string_literal: true

class AddCredisCaptureEpochEvidence < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_capture_epochs, :compatibility_token, :string
    add_column :credis_capture_epochs, :baseline_digest, :string
    add_column :credis_capture_epochs, :baseline_source_scope, :jsonb
    add_column :credis_capture_epochs, :baseline_counts, :jsonb
    add_column :credis_capture_epochs, :baseline_watermarks, :jsonb
    add_column :credis_capture_epochs, :incomplete_reason, :string
    add_column :credis_capture_epochs, :quarantine_scope, :jsonb

    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      DROP CONSTRAINT credis_capture_epochs_status_check
    SQL
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_status_check
      CHECK (status IN ('baselining', 'collecting', 'incomplete', 'closed'))
    SQL
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_baseline_evidence_check
      CHECK (
        baseline_complete = FALSE OR (
          compatibility_token IS NOT NULL AND
          baseline_digest ~ '^[0-9a-f]{64}$' AND
          baseline_source_scope IS NOT NULL AND
          baseline_counts IS NOT NULL AND
          baseline_watermarks IS NOT NULL
        )
      )
    SQL
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_collecting_certified_check
      CHECK (status <> 'collecting' OR baseline_complete = TRUE)
    SQL
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_incomplete_uncertified_check
      CHECK (status <> 'incomplete' OR baseline_complete = FALSE)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis epoch completeness evidence must be retained and migrated forward"
  end
end
