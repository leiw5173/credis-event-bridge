# frozen_string_literal: true

module CredisEventBridge
  class EpochLifecycle
    class Error < StandardError
    end

    class AlreadyCollecting < Error
    end

    class NotCollecting < Error
    end

    AUTHORIZATION_KEY = :credis_event_bridge_epoch_transition_authorization
    GLOBAL_QUARANTINE = {
      "relation_kinds" => %w[interaction bookmark],
      "scope" => "all_plugin_supported_relations",
    }.freeze

    class << self
      def start!(page_size: Baseline::DEFAULT_PAGE_SIZE, max_rows: Baseline::DEFAULT_MAX_ROWS)
        activate!(page_size: page_size, max_rows: max_rows, rotate: false)
      end

      # Close and activate under one exclusive source lock and one commit.
      # Unlike disable/start, this creates no unobserved source interval.
      def rotate!(page_size: Baseline::DEFAULT_PAGE_SIZE, max_rows: Baseline::DEFAULT_MAX_ROWS)
        activate!(page_size: page_size, max_rows: max_rows, rotate: true)
      end

      def activate!(page_size:, max_rows:, rotate:)
        ensure_compatible!
        epoch = nil
        with_activation_transaction do
          Capture.lock_epoch_transition!
          Baseline.lock_featured_sources!
          Baseline.lock_report_sources!
          ensure_compatible!
          collecting = CredisCaptureEpoch.lock.find_by(status: "collecting")
          if rotate
            raise NotCollecting, "epoch rotation requires a collecting epoch" if !collecting
            boundary = Time.zone.now
            authorized_transition { collecting.update!(status: "closed", ended_at: boundary) }
          else
            raise AlreadyCollecting, "a certified capture epoch is already collecting" if collecting
            close_controlled_gap!
            boundary = Time.zone.now
          end
          epoch =
            authorized_transition do
              CredisCaptureEpoch.create!(
                started_at: boundary,
                baseline_complete: false,
                status: "baselining",
              )
            end
          evidence = Baseline.new(page_size: page_size, max_rows: max_rows, preserve_reports: rotate).scan!
          ensure_compatible!
          if evidence.manifest.dig("snapshot", "external_current_verified")
            begin
              ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '5s'")
              ActiveRecord::Base.connection.execute("LOCK TABLE site_settings IN SHARE MODE")
            rescue ActiveRecord::StatementInvalid => error
              raise Baseline::Incomplete, "setting lock unavailable: #{error.class}"
            end
          end
          if !Baseline.activation_manifest_current?(evidence.manifest, digest: evidence.digest)
            raise Baseline::Incomplete, "baseline manifest changed during baseline"
          end
          verified_at = Time.zone.now
          authorized_transition do
            epoch.update!(
              status: "collecting",
              baseline_complete: true,
              compatibility_token: SourceCompatibility::EXPECTED_TOKEN,
              baseline_digest: evidence.digest,
              baseline_manifest: evidence.manifest,
              baseline_source_scope: evidence.source_scope,
              baseline_counts: evidence.counts,
              baseline_watermarks: evidence.watermarks,
              last_verified_at: verified_at,
              incomplete_reason: nil,
              quarantine_scope: nil,
            )
          end
        end
        epoch.reload
      rescue Baseline::Incomplete
        if rotate
          mark_incomplete!(reason: "epoch_rotation_baseline_failed")
        else
          record_failed_baseline!(reason: "baseline_incomplete")
        end
        raise
      rescue SourceCompatibility::Error
        if rotate
          mark_incomplete!(reason: "epoch_rotation_compatibility_failed")
        else
          record_failed_baseline!(reason: "source_compatibility_failure")
        end
        raise
      end
      private :activate!

      def disable!(reason:)
        raise ArgumentError, "disable reason is required" if reason.blank?

        gap = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          Capture.lock_epoch_transition!
          now = Time.zone.now
          collecting = CredisCaptureEpoch.lock.find_by(status: "collecting")
          authorized_transition do
            collecting&.update!(status: "closed", ended_at: now)
            gap =
              CredisCaptureEpoch.create!(
                started_at: now,
                baseline_complete: false,
                status: "incomplete",
                incomplete_reason: "controlled_disable_gap",
                quarantine_scope: global_quarantine.merge("operator_reason" => reason),
              )
          end
        end
        gap.reload
      end

      def mark_incomplete!(reason:, scope: nil, at: Time.zone.now)
        raise ArgumentError, "incomplete reason is required" if reason.blank?
        scope ||= global_quarantine

        epoch = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          Capture.lock_epoch_transition!
          epoch = CredisCaptureEpoch.lock.find_by(status: "collecting")
          if epoch
            quarantine = stringify(scope)
            quarantine["from_verified_at"] =
              (epoch.last_verified_at || epoch.started_at).utc.iso8601(6)
            quarantine["through"] = at.utc.iso8601(6)
            authorized_transition do
              epoch.update!(
                status: "incomplete",
                baseline_complete: false,
                ended_at: at,
                incomplete_reason: reason,
                quarantine_scope: quarantine,
              )
            end
          end
        end
        epoch&.reload
      end

      def recover_uncontrolled_restart!
        return if !evidence_columns_available?

        mark_incomplete!(reason: "uncontrolled_restart")
      end

      def transition_authorized?
        Thread.current[AUTHORIZATION_KEY].to_i.positive?
      end

      private

      def global_quarantine
        GLOBAL_QUARANTINE.merge("relation_kinds" => Baseline.target_types.keys)
      end

      def with_activation_transaction
        if ActiveRecord::Base.connection.transaction_open?
          raise Error, "capture activation cannot join an existing transaction" if !Rails.env.test?

          ActiveRecord::Base.transaction(requires_new: true) { yield }
        else
          Capture.with_epoch_transition_session_lock do
            ActiveRecord::Base.transaction(
              requires_new: true,
              isolation: :repeatable_read,
            ) { yield }
          end
        end
      end

      def ensure_compatible!
        return true if SourceCompatibility.current? && CredisEventBridge.source_extensions_complete?

        raise SourceCompatibility::Error,
              "capture baseline requires current source compatibility and exact hooks"
      end

      def authorized_transition
        depth = Thread.current[AUTHORIZATION_KEY].to_i
        Thread.current[AUTHORIZATION_KEY] = depth + 1
        yield
      ensure
        Thread.current[AUTHORIZATION_KEY] = depth
      end

      def close_controlled_gap!
        gaps =
          CredisCaptureEpoch.lock.where(
            status: "incomplete",
            incomplete_reason: "controlled_disable_gap",
            ended_at: nil,
          )
        authorized_transition { gaps.update_all(ended_at: Time.zone.now, updated_at: Time.zone.now) }
      end

      def record_failed_baseline!(reason:)
        return if !evidence_columns_available?

        ActiveRecord::Base.transaction(requires_new: true) do
          Capture.lock_epoch_transition!
          now = Time.zone.now
          authorized_transition do
            CredisCaptureEpoch.where(status: "baselining").update_all(
              status: "incomplete",
              baseline_complete: false,
              ended_at: now,
              incomplete_reason: reason,
              quarantine_scope: global_quarantine,
              updated_at: now,
            )
            CredisCaptureEpoch.create!(
              started_at: now,
              ended_at: now,
              baseline_complete: false,
              status: "incomplete",
              incomplete_reason: reason,
              quarantine_scope: global_quarantine,
            ) if !CredisCaptureEpoch.exists?(
              status: "incomplete",
              incomplete_reason: reason,
              started_at: now,
            )
          end
        end
      rescue ActiveRecord::ActiveRecordError => error
        Rails.logger.error(
          "Credis event bridge could not persist failed baseline evidence: #{error.class}",
        )
      end

      def evidence_columns_available?
        connection = ActiveRecord::Base.connection
        connection.data_source_exists?(CredisCaptureEpoch.table_name) &&
          connection.column_exists?(CredisCaptureEpoch.table_name, :baseline_manifest)
      rescue ActiveRecord::NoDatabaseError, PG::ConnectionBad
        false
      end

      def stringify(value)
        value.deep_stringify_keys
      end
    end
  end
end
