# frozen_string_literal: true

module CredisEventBridge
  class EventPayload
    BUSINESS_FIELDS = %i[
      event_uid
      epoch_id
      relation_kind
      actor_user_id
      target_type
      target_id
      revision
      operation_id
      from_state
      to_state
      occurred_at
      origin
    ].freeze
    SNAPSHOT_FIELDS = %i[
      snapshot_schema_version
      target_author_user_id
      target_post_version
      target_content_status
      target_deleted
      target_hidden
      target_user_deleted
      target_snapshot_captured_at
      reaction_settings_digest
    ].freeze

    CONTEXT_FIELDS = %i[target_context].freeze
    FEATURED_FIELDS = %i[featured_tag_id featured_post_id featured_operator_user_id].freeze
    REPORT_FIELDS = %i[report_evidence_id report_post_id].freeze

    class << self
      def call(event)
        fields = BUSINESS_FIELDS
        fields += SNAPSHOT_FIELDS if event.snapshot_schema_version.present?
        fields += CONTEXT_FIELDS if event.snapshot_schema_version.to_i >= 2
        fields += FEATURED_FIELDS if event.relation_kind == "featured"
        fields += REPORT_FIELDS if event.relation_kind == "flag"
        fields += [:badge_snapshot] if event.relation_kind == "badge"
        event
          .attributes
          .slice(*fields.map(&:to_s))
          .transform_values { |value| value.is_a?(Time) ? value.iso8601(6) : value }
      end
    end
  end
end
