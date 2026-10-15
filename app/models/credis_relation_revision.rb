# frozen_string_literal: true

class CredisRelationRevision < ActiveRecord::Base
  self.primary_key = :relation_revision_id

  IDENTITY_FIELDS = %i[relation_kind actor_user_id target_type target_id featured_tag_id].freeze

  attr_readonly(*IDENTITY_FIELDS)

  has_many :events,
           class_name: "CredisEventOutbox",
           foreign_key: :relation_revision_id,
           inverse_of: :relation_revision

  validates :relation_kind, :actor_user_id, :target_type, :target_id, :state_code, presence: true
  validates :revision, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
