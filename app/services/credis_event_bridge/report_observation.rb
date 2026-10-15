# frozen_string_literal: true

module CredisEventBridge
  class ReportObservation
    class Unavailable < StandardError
    end

    def self.capture!(reviewable_id)
      raise Unavailable if !ReportSource::ENABLED || !SourceCompatibility.current?

      ActiveRecord::Base.transaction do
        CredisReportObservationFence.create!(fence_id: SecureRandom.uuid,
          reviewable_id: reviewable_id, compatibility_token: SourceCompatibility::EXPECTED_TOKEN).reload
      end
    rescue ActiveRecord::StatementInvalid
      raise Unavailable
    end
  end
end
