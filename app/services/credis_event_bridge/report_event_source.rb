# frozen_string_literal: true

module CredisEventBridge
  # Observation revisions retain changes within the same Reviewable decision.
  # Eligibility is decided from the authenticated native history downstream.
  class ReportEventSource
    class << self
      def record!(evidence)
        raise Operation::TransactionRequired, "Report events require the source transaction" if !DB.transaction_open?

        snapshot = evidence.source_snapshot.fetch("core")
        previous = CredisReportEvidence.find_by(id: evidence.previous_evidence_id)
        actors = reporter_ids(snapshot)
        actors.concat(reporter_ids(previous.source_snapshot.fetch("core"))) if previous
        actors.concat(CredisRelationRevision.where(relation_kind: "flag", target_type: "Reviewable", target_id: evidence.reviewable_id).pluck(:actor_user_id))
        actors.select(&:positive?).uniq.sort.each do |actor|
          identity = { relation_kind: "flag", actor_user_id: actor, target_type: "Reviewable", target_id: evidence.reviewable_id, featured_tag_id: nil }
          relation = CredisRelationRevision.find_or_create_by!(identity) do |row|
            row.state_code = "unknown"
            row.revision = 0
          end
          relation.lock!
          state = "observed:#{evidence.revision}"
          next if relation.state_code == state

          before = relation.state_code
          relation.update!(state_code: state, revision: relation.revision + 1)
          CredisEventOutbox.create!(**identity, event_uid: SecureRandom.uuid,
            epoch_id: evidence.epoch_id, relation_revision_id: relation.relation_revision_id,
            revision: relation.revision, operation_id: SecureRandom.uuid,
            from_state: before, to_state: state, occurred_at: evidence.occurred_at,
            origin: evidence.origin, report_evidence_id: evidence.id,
            report_post_id: snapshot.fetch("reviewable").fetch("target_id"))
        end
      end

      def reporter_ids(core)
        core.fetch("scores").map { |score| score.fetch("user_id") }.compact
      end
    end
  end
end
