# frozen_string_literal: true

class CredisEventOutbox < ActiveRecord::Base
  self.table_name = :credis_event_outbox
  self.primary_key = :outbox_id

  BUSINESS_FIELDS = %i[
    outbox_id
    event_uid
    epoch_id
    relation_revision_id
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
    created_at
    snapshot_schema_version
    target_author_user_id
    target_post_version
    target_content_status
    target_deleted
    target_hidden
    target_user_deleted
    target_snapshot_captured_at
    reaction_settings_digest
    target_context
    featured_tag_id
    featured_post_id
    featured_operator_user_id
    report_evidence_id
    report_post_id
    badge_snapshot
  ].freeze

  belongs_to :capture_epoch,
             class_name: "CredisCaptureEpoch",
             foreign_key: :epoch_id,
             inverse_of: :events
  belongs_to :relation_revision,
             class_name: "CredisRelationRevision",
             foreign_key: :relation_revision_id,
             inverse_of: :events

  attr_readonly(*BUSINESS_FIELDS)
end
