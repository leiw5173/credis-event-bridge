# frozen_string_literal: true

require_relative "../../app/services/credis_event_bridge/report_append_authority"

class CreateCredisReportEvidence < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_report_evidence do |t|
      t.uuid :evidence_uid, null: false
      t.bigint :epoch_id, null: false
      t.bigint :reviewable_id, null: false
      t.bigint :revision, null: false
      t.bigint :previous_evidence_id
      t.bigint :operator_user_id, null: false
      t.string :origin, null: false
      t.datetime :occurred_at, null: false, default: -> { "clock_timestamp()" }
      t.jsonb :source_snapshot, null: false
    end
    add_index :credis_report_evidence, :evidence_uid, unique: true
    add_index :credis_report_evidence, %i[reviewable_id revision], unique: true
    add_foreign_key :credis_report_evidence, :credis_capture_epochs, column: :epoch_id, primary_key: :epoch_id
    add_foreign_key :credis_report_evidence, :credis_report_evidence, column: :previous_evidence_id
    execute <<~SQL
      ALTER TABLE credis_report_evidence ADD CONSTRAINT credis_report_identity CHECK (
        reviewable_id>0 AND revision>0 AND (operator_user_id>0 OR operator_user_id=-1)
        AND ((revision=1 AND previous_evidence_id IS NULL) OR (revision>1 AND previous_evidence_id IS NOT NULL))
        AND origin IN ('flag_submitted','flag_withdrawn','reviewable_transition')
      );
      CREATE FUNCTION credis_report_core_snapshot(reviewable_key bigint) RETURNS jsonb
        LANGUAGE sql STABLE AS $snapshot$#{CredisEventBridge::ReportAppendAuthority::SNAPSHOT_BODY}$snapshot$;
      CREATE FUNCTION certify_credis_report_append() RETURNS trigger
        LANGUAGE plpgsql AS $authority$#{CredisEventBridge::ReportAppendAuthority::APPEND_BODY}$authority$;
      CREATE FUNCTION protect_credis_report_evidence() RETURNS trigger
        LANGUAGE plpgsql AS $immutable$#{CredisEventBridge::ReportAppendAuthority::IMMUTABLE_BODY}$immutable$;
      CREATE TRIGGER credis_report_append_authority BEFORE INSERT ON credis_report_evidence
        FOR EACH ROW EXECUTE FUNCTION certify_credis_report_append();
      CREATE TRIGGER credis_report_evidence_immutable BEFORE UPDATE OR DELETE ON credis_report_evidence
        FOR EACH ROW EXECUTE FUNCTION protect_credis_report_evidence();
      CREATE TRIGGER credis_report_evidence_no_truncate BEFORE TRUNCATE ON credis_report_evidence
        FOR EACH STATEMENT EXECUTE FUNCTION protect_credis_report_evidence();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Report source history and migrate forward"
  end
end
