# frozen_string_literal: true

class AddCredisBaselineManifest < ActiveRecord::Migration[8.0]
  def up
    add_column :credis_capture_epochs, :baseline_manifest, :jsonb

    execute <<~SQL
      UPDATE credis_capture_epochs
      SET
        baseline_complete = FALSE,
        status = CASE WHEN status = 'collecting' THEN 'incomplete' ELSE status END,
        ended_at = CASE
          WHEN status = 'collecting' THEN COALESCE(ended_at, CURRENT_TIMESTAMP)
          ELSE ended_at
        END,
        incomplete_reason = COALESCE(incomplete_reason, 'baseline_manifest_missing'),
        quarantine_scope = CASE
          WHEN status = 'collecting' THEN COALESCE(
            quarantine_scope,
            '{"relation_kinds":["interaction","bookmark"],"scope":"all_plugin_supported_relations"}'::jsonb
          )
          ELSE quarantine_scope
        END,
        updated_at = CURRENT_TIMESTAMP
      WHERE baseline_complete = TRUE
    SQL

    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      DROP CONSTRAINT credis_capture_epochs_baseline_evidence_check
    SQL
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_baseline_evidence_check
      CHECK (
        baseline_complete = FALSE OR (
          compatibility_token IS NOT NULL AND
          baseline_digest ~ '^[0-9a-f]{64}$' AND
          baseline_manifest IS NOT NULL AND
          baseline_source_scope IS NOT NULL AND
          baseline_counts IS NOT NULL AND
          baseline_watermarks IS NOT NULL
        )
      )
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis certified baseline manifests must be retained and migrated forward"
  end
end
