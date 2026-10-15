# frozen_string_literal: true

class CredisHistoryReplaySession < ActiveRecord::Base
  self.primary_key = :replay_session_id

  QUERY_FIELDS = %i[
    replay_session_id
    epoch_id
    from_occurred_at
    to_occurred_at
    page_limit
    expires_at
    created_at
  ].freeze

  attr_readonly(*QUERY_FIELDS)

  belongs_to :capture_epoch,
             class_name: "CredisCaptureEpoch",
             foreign_key: :epoch_id
  has_many :memberships,
           class_name: "CredisHistoryReplayMembership",
           foreign_key: :replay_session_id,
           dependent: :delete_all,
           inverse_of: :replay_session

  validates :epoch_id, :from_occurred_at, :to_occurred_at, :expires_at, presence: true
  validates :page_limit,
            numericality: {
              only_integer: true,
              greater_than: 0,
              less_than_or_equal_to: 100,
            }
end
