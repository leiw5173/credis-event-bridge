# frozen_string_literal: true

class CredisHistoryReplayMembership < ActiveRecord::Base
  self.primary_key = nil

  attr_readonly :replay_session_id, :outbox_id, :position, :created_at

  belongs_to :replay_session,
             class_name: "CredisHistoryReplaySession",
             foreign_key: :replay_session_id,
             inverse_of: :memberships
  belongs_to :event,
             class_name: "CredisEventOutbox",
             foreign_key: :outbox_id

  validates :replay_session_id, :outbox_id, presence: true
  validates :position, numericality: { only_integer: true, greater_than: 0 }
end
