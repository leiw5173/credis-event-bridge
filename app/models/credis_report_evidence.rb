# frozen_string_literal: true

class CredisReportEvidence < ActiveRecord::Base
  self.table_name = "credis_report_evidence"

  attr_readonly :evidence_uid, :epoch_id, :reviewable_id, :revision,
                :previous_evidence_id, :operator_user_id, :origin, :occurred_at, :source_snapshot
end
