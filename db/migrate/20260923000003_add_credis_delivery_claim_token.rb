# frozen_string_literal: true

class AddCredisDeliveryClaimToken < ActiveRecord::Migration[8.0]
  def change
    add_column :credis_event_outbox, :delivery_claim_token, :uuid
    add_index :credis_event_outbox,
              :delivery_claim_token,
              unique: true,
              where: "delivery_claim_token IS NOT NULL",
              name: :idx_credis_outbox_delivery_claim_token
  end
end
