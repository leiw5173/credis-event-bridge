# frozen_string_literal: true

module CredisEventBridge
  class ReportObservationsController < EventsController
    def create
      return render_bad_request if request.query_parameters.present? || request.raw_post.present?

      raw_id = params[:reviewable_id].to_s
      return render_bad_request if
        !/\A[1-9]\d*\z/.match?(raw_id) || raw_id.length > 19 || raw_id.to_i > 9_223_372_036_854_775_807

      marker = ReportObservation.capture!(raw_id.to_i)
      render json: {
        evidence_schema_version: 1, reviewable_id: marker.reviewable_id, fence_id: marker.fence_id,
        observed_at: marker.observed_at.utc.iso8601(6), latest_evidence_id: marker.latest_evidence_id,
        compatibility_token: marker.compatibility_token, core: marker.core_snapshot,
      }
    rescue ReportObservation::Unavailable
      render json: { error: "Report observation unavailable" }, status: :service_unavailable
    end
  end
end
