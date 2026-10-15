# frozen_string_literal: true

module CredisEventBridge
  class HistoryReplay
    SESSION_TTL = 1.hour
    CLEANUP_BATCH_SIZE = 100

    class << self
      def start!(query:, now: Time.zone.now)
        session_id = SecureRandom.uuid
        expires_at = now + SESSION_TTL
        from_occurred_at = Time.iso8601(query.fetch("from_occurred_at"))
        to_occurred_at = Time.iso8601(query.fetch("to_occurred_at"))
        DB.exec(
          <<~SQL,
            WITH new_session AS (
              INSERT INTO credis_history_replay_sessions (
                replay_session_id,
                epoch_id,
                from_occurred_at,
                to_occurred_at,
                page_limit,
                expires_at,
                created_at,
                updated_at
              ) VALUES (
                :replay_session_id,
                :epoch_id,
                :from_occurred_at,
                :to_occurred_at,
                :page_limit,
                :expires_at,
                :created_at,
                :created_at
              )
              RETURNING replay_session_id
            ), snapshot_events AS (
              SELECT
                outbox_id,
                ROW_NUMBER() OVER (ORDER BY occurred_at, event_uid) AS position
              FROM credis_event_outbox
              WHERE epoch_id = :epoch_id
                AND occurred_at >= :from_occurred_at
                AND occurred_at <= :to_occurred_at
            )
            INSERT INTO credis_history_replay_memberships (
              replay_session_id,
              outbox_id,
              position,
              created_at
            )
            SELECT
              new_session.replay_session_id,
              snapshot_events.outbox_id,
              snapshot_events.position,
              :created_at
            FROM new_session
            CROSS JOIN snapshot_events
          SQL
          replay_session_id: session_id,
          epoch_id: query.fetch("epoch_id"),
          from_occurred_at: from_occurred_at,
          to_occurred_at: to_occurred_at,
          page_limit: query.fetch("limit"),
          expires_at: expires_at,
          created_at: now,
        )
        CredisHistoryReplaySession.find(session_id)
      end

      def cleanup_expired!(now: Time.zone.now, limit: CLEANUP_BATCH_SIZE)
        raise ArgumentError, "cleanup limit must be bounded" if !limit.to_i.between?(1, CLEANUP_BATCH_SIZE)

        session_ids =
          CredisHistoryReplaySession
            .where("expires_at <= ?", now)
            .order(:expires_at, :replay_session_id)
            .limit(limit.to_i)
            .pluck(:replay_session_id)
        return 0 if session_ids.empty?

        CredisHistoryReplaySession.where(replay_session_id: session_ids).delete_all
      end

      def page(session:, after_position:)
        session
          .memberships
          .where("position > ?", after_position)
          .includes(:event)
          .order(:position)
          .limit(session.page_limit + 1)
          .to_a
      end
    end
  end
end
