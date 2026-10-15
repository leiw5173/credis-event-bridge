# frozen_string_literal: true

require_relative "../../app/services/credis_event_bridge/report_observation_authority"

class CreateCredisReportObservationFences < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_report_observation_fences, id: false do |t|
      t.uuid :fence_id, primary_key: true
      t.bigint :reviewable_id, null: false
      t.datetime :observed_at, null: false
      t.bigint :latest_evidence_id
      t.string :compatibility_token, null: false
      t.jsonb :core_snapshot, null: false
    end
    add_foreign_key :credis_report_observation_fences, :credis_report_evidence, column: :latest_evidence_id
    add_check_constraint :credis_report_observation_fences,
                         "reviewable_id>0 AND (latest_evidence_id IS NULL OR latest_evidence_id>0) AND compatibility_token ~ '^[0-9a-f]{64}$'",
                         name: :credis_report_observation_identity
    execute <<~SQL
      CREATE FUNCTION certify_credis_report_observation() RETURNS trigger
        LANGUAGE plpgsql AS $authority$#{CredisEventBridge::ReportObservationAuthority::APPEND_BODY}$authority$;
      CREATE FUNCTION protect_credis_report_observation() RETURNS trigger
        LANGUAGE plpgsql AS $immutable$#{CredisEventBridge::ReportObservationAuthority::IMMUTABLE_BODY}$immutable$;
      CREATE TRIGGER credis_report_observation_append BEFORE INSERT ON credis_report_observation_fences
        FOR EACH ROW EXECUTE FUNCTION certify_credis_report_observation();
      CREATE TRIGGER credis_report_observation_immutable BEFORE UPDATE OR DELETE ON credis_report_observation_fences
        FOR EACH ROW EXECUTE FUNCTION protect_credis_report_observation();
      CREATE TRIGGER credis_report_observation_no_truncate BEFORE TRUNCATE ON credis_report_observation_fences
        FOR EACH STATEMENT EXECUTE FUNCTION protect_credis_report_observation();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Report observations and migrate forward"
  end
end
