# frozen_string_literal: true

module CredisEventBridge
  class DemoFormsController < ::ApplicationController
    requires_plugin CredisEventBridge::PLUGIN_NAME
    requires_login
    before_action :ensure_admin, only: :review

    def submit
      evidence = DemoFormSource.submit!(post_id: params[:post_id], actor: current_user,
        input: params.require(:submission).permit(:evidence_uid, :form_template_id, :field_key, fields: {}).to_h)
      render json: response_for(evidence)
    rescue DemoFormSource::Invalid
      render json: { error: "invalid form submission" }, status: :unprocessable_entity
    rescue DemoFormSource::Conflict
      render json: { error: "form evidence conflict" }, status: :conflict
    rescue DemoFormSource::Unavailable
      render json: { error: "form capture unavailable" }, status: :service_unavailable
    end

    def review
      evidence = DemoFormSource.review!(post_id: params[:post_id], actor: current_user,
        evidence_uid: params[:evidence_uid], expected_revision: params[:expected_revision],
        state: params[:state], reason: params[:reason])
      render json: response_for(evidence)
    rescue DemoFormSource::Invalid
      render json: { error: "invalid form review" }, status: :unprocessable_entity
    rescue DemoFormSource::Conflict
      render json: { error: "form evidence conflict" }, status: :conflict
    rescue DemoFormSource::Unavailable
      render json: { error: "form capture unavailable" }, status: :service_unavailable
    end

    private

    def response_for(evidence)
      { evidence_uid: evidence.evidence_uid, revision: evidence.revision, state: evidence.state_code }
    end
  end
end
