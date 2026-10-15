# frozen_string_literal: true

class CredisReportObservationFence < ActiveRecord::Base
  self.table_name = "credis_report_observation_fences"
  self.primary_key = "fence_id"

  attr_readonly :fence_id, :reviewable_id, :observed_at, :latest_evidence_id,
                :compatibility_token, :core_snapshot
end
