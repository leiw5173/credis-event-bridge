# frozen_string_literal: true

module CredisEventBridge
  # Only before first activation. The caller must enforce database read-only
  # from before Rails boot; initializers are not part of this check.
  class DeploymentPreflight
    SOURCES = %w[
      active_post_likes
      reaction_users
      post_bookmarks
      existing_bridge_relations
      regular_posts
      demo_form_evidence
      demo_tag_reviews
      demo_tag_revision_projections
      solved_answers
      featured_topics
      user_badges
      reports
    ].freeze

    def self.verify_boot!
      unless ActiveRecord::Base.connection.select_value("SHOW default_transaction_read_only") ==
               "on" && !CredisCaptureEpoch.exists?
        raise "first-start preflight requires read-only database and no source history"
      end
    end

    def self.check
      return { ready: false, reasons: ["source_history_exists"] } if CredisCaptureEpoch.exists?

      reasons = []
      reasons << "source_incompatible" unless SourceCompatibility.current?
      reasons << "source_families_incomplete" unless Baseline.sources == SOURCES
      reactions = Baseline.reaction_settings
      unless reactions.fetch("enabled") == true && reactions.fetch("enabled_codes").is_a?(Array) &&
               !reactions.fetch("enabled_codes").empty?
        reasons << "reactions_ineligible"
      end
      solved = Baseline.solved_settings
      unless solved.fetch("enabled") == true && solved.fetch("allow_multiple_solutions") == false
        reasons << "solved_ineligible"
      end
      tag_id = DemoTagReviewSource.configured_tag_id
      reasons << "demo_tag_missing" unless tag_id.positive? && Tag.exists?(id: tag_id)
      return { ready: false, reasons: reasons } unless reasons.empty?

      pin =
        ActiveRecord::Base.connection.select_one(
          "SELECT system_identifier::text AS system_id, current_database() AS database FROM pg_control_system()",
        )
      { ready: true, reasons: [], source_pin: pin }
    rescue StandardError
      { ready: false, reasons: ["preflight_unavailable"] }
    end
  end
end
