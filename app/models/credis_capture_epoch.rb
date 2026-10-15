# frozen_string_literal: true

class CredisCaptureEpoch < ActiveRecord::Base
  self.table_name = :credis_capture_epochs
  self.primary_key = :epoch_id

  has_many :events,
           class_name: "CredisEventOutbox",
           foreign_key: :epoch_id,
           inverse_of: :capture_epoch

  validates :started_at, :status, presence: true
  validates :status, inclusion: { in: %w[baselining collecting incomplete closed] }
  validates :compatibility_token,
            :baseline_digest,
            :baseline_manifest,
            :baseline_source_scope,
            :baseline_counts,
            :baseline_watermarks,
            presence: true,
            if: :baseline_complete?
  validates :baseline_digest,
            format: { with: /\A[0-9a-f]{64}\z/ },
            allow_nil: true
  validate :collecting_requires_complete_baseline
  validate :incomplete_cannot_claim_complete_baseline

  def certified_collecting?
    status == "collecting" && baseline_complete? &&
      compatibility_token == CredisEventBridge::SourceCompatibility::EXPECTED_TOKEN &&
      baseline_manifest.is_a?(Hash) &&
      baseline_manifest["compatibility_token"] == compatibility_token &&
      baseline_manifest["source_scope"] == baseline_source_scope &&
      baseline_manifest["counts"] == baseline_counts &&
      baseline_manifest["watermarks"] == baseline_watermarks &&
      CredisEventBridge::Baseline.manifest_current?(
        baseline_manifest,
        digest: baseline_digest,
      )
  end

  private

  def collecting_requires_complete_baseline
    return if status != "collecting" || baseline_complete?

    errors.add(:status, "requires a complete certified baseline")
  end

  def incomplete_cannot_claim_complete_baseline
    return if status != "incomplete" || !baseline_complete?

    errors.add(:baseline_complete, "must be false for an incomplete epoch")
  end
end
