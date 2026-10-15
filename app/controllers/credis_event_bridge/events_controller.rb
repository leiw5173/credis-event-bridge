# frozen_string_literal: true

module CredisEventBridge
  InvalidAck = Class.new(StandardError)
  MissingAckEvent = Class.new(StandardError)

  class EventsController < ::ApplicationController
    requires_plugin CredisEventBridge::PLUGIN_NAME

    MAX_LIMIT = 100
    MAX_HISTORY_RANGE = 31.days
    UUID_PATTERN =
      /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

    skip_before_action :redirect_to_login_if_required,
                       :preload_json,
                       :check_xhr,
                       :verify_authenticity_token
    before_action :authenticate_integration!

    def index
      return render_bad_request if request.query_parameters.keys.any? { |key| key != "limit" }

      limit = validated_limit
      return render_bad_request if !limit

      events = CredisEventOutbox.where(acked_at: nil).order(:outbox_id).limit(limit)
      render json: { events: events.map { |event| EventPayload.call(event) } }
    end

    def ack
      event_uids = validated_ack_uids
      now = Time.zone.now
      ActiveRecord::Base.transaction do
        events = CredisEventOutbox.lock.where(event_uid: event_uids).to_a
        raise MissingAckEvent if events.length != event_uids.length

        CredisEventOutbox
          .where(event_uid: event_uids, acked_at: nil)
          .update_all(
            acked_at: now,
            delivery_claim_token: nil,
            next_attempt_at: nil,
            last_delivery_error: nil,
            updated_at: now,
          )
      end
      render json: { acked_event_uids: event_uids }
    rescue InvalidAck, JSON::ParserError
      render_bad_request
    rescue MissingAckEvent
      render json: { error: "unknown event UID" }, status: :unprocessable_entity
    end

    def history
      history_query = validated_history_query
      return render_bad_request if !history_query

      now = Time.zone.now
      binding = history_query.fetch(:binding)
      if history_query[:page_token].present?
        token =
          HistoryPageToken.decode(
            history_query.fetch(:page_token),
            query: binding,
            now: now,
          )
        session =
          CredisHistoryReplaySession.find_by(
            replay_session_id: token.fetch(:session_id),
          )
        raise HistoryPageToken::Invalid if
          !valid_history_session?(session, binding: binding, token: token, now: now)
        after_position = token.fetch(:after_position)
      else
        session = HistoryReplay.start!(query: binding, now: now)
        after_position = 0
      end

      memberships = HistoryReplay.page(session: session, after_position: after_position)
      has_more = memberships.length > session.page_limit
      memberships = memberships.first(session.page_limit)
      next_page_token =
        if has_more
          HistoryPageToken.encode(
            query: binding,
            session: session,
            after_position: memberships.last.position,
          )
        end
      Rails.logger.info(
        "Credis event bridge history replay session=#{session.id} epoch=#{session.epoch_id} rows=#{memberships.length}",
      )
      render json: {
               events: memberships.map { |membership| EventPayload.call(membership.event) },
               next_page_token: next_page_token,
             }
    rescue HistoryPageToken::Invalid
      render_bad_request
    end

    def epoch
      return render_bad_request if request.query_parameters.present?

      raw_id = params[:epoch_id].to_s
      return render_bad_request if
        !/\A[1-9]\d*\z/.match?(raw_id) || raw_id.length > 19 ||
          raw_id.to_i > 9_223_372_036_854_775_807

      capture_epoch = CredisCaptureEpoch.find_by(epoch_id: raw_id.to_i)
      return render json: { error: "unknown epoch" }, status: :not_found if !capture_epoch

      reaction_settings = capture_epoch.baseline_manifest&.dig("reaction_settings")
      reaction_settings_digest =
        Baseline.digest_manifest(reaction_settings) if reaction_settings.is_a?(Hash)

      render json: {
               evidence_schema_version: 1,
               epoch_id: capture_epoch.epoch_id,
               status: capture_epoch.status,
               started_at: capture_epoch.started_at.utc.iso8601(6),
               ended_at: capture_epoch.ended_at&.utc&.iso8601(6),
               last_verified_at: capture_epoch.last_verified_at&.utc&.iso8601(6),
               baseline_complete: capture_epoch.baseline_complete?,
               compatibility_token: capture_epoch.compatibility_token,
               baseline_digest: capture_epoch.baseline_digest,
               reaction_settings_digest: reaction_settings_digest,
               source_scope: capture_epoch.baseline_source_scope,
               incomplete_reason: capture_epoch.incomplete_reason,
               quarantine_scope: capture_epoch.quarantine_scope,
               closed_complete: capture_epoch.status == "closed" && capture_epoch.baseline_complete?,
             }
    end

    def post_evidence
      return render_bad_request if request.query_parameters.present?

      post_id = validated_post_id
      return render_bad_request if !post_id

      render_post_evidence(post_evidence_row(post_id: post_id))
    end

    # This signed POST writes a published marker in the same source statement
    # that observes the Post. Its commit becomes the CDC catch-up boundary.
    def fenced_post_evidence
      return render_bad_request if request.query_parameters.present? || request.raw_post.present?

      post_id = validated_post_id
      return render_bad_request if !post_id

      fence_id = SecureRandom.uuid
      post = post_evidence_row(post_id: post_id, fence_id: fence_id)
      return render_post_evidence(post) if !post
      return render json: { error: "Post fence unavailable" }, status: :service_unavailable if
        post.fence_id != fence_id

      if !post.post_exists
        return render json: {
          evidence_schema_version: 5,
          post_id: post.post_id,
          observed_at: post.observed_at.utc.iso8601(6),
          fence_id: post.fence_id,
          post_exists: false,
        }
      end

      render_post_evidence(post, fence_id: post.fence_id)
    end

    private

    def validated_post_id
      raw_id = params[:post_id].to_s
      return if
        !/\A[1-9]\d*\z/.match?(raw_id) || raw_id.length > 19 ||
          raw_id.to_i > 9_223_372_036_854_775_807

      raw_id.to_i
    end

    def post_evidence_row(post_id:, fence_id: nil)
      # One SQL statement gives Post, Topic and Category flags from the same
      # PostgreSQL snapshot. The fenced path inserts its marker from these
      # exact observed rows in the same statement and source transaction.
      source_sql = <<~SQL
        SELECT p.id AS post_id, p.user_id AS author_user_id, p.topic_id,
          p.post_number, p.version AS post_version, p.post_type,
          p.deleted_at IS NOT NULL AS deleted, p.hidden, p.user_deleted,
          t.id AS matched_topic_id, t.deleted_at IS NOT NULL AS topic_deleted,
          t.visible AS topic_visible, t.archetype AS topic_archetype,
          t.category_id,
          c.id AS matched_category_id, COALESCE(c.read_restricted, FALSE) AS category_read_restricted,
          statement_timestamp() AS observed_at
        FROM posts p
        LEFT JOIN topics t ON t.id = p.topic_id
        LEFT JOIN categories c ON c.id = t.category_id
        WHERE p.id = :post_id
      SQL

      return DB.query(source_sql, post_id: post_id).first if !fence_id

      DB.query(<<~SQL, post_id: post_id, fence_id: fence_id).first
        WITH observed AS MATERIALIZED (
          SELECT present.*, TRUE AS post_exists FROM (#{source_sql}) present
          UNION ALL
          SELECT CAST(:post_id AS bigint), NULL::bigint, NULL::bigint,
            NULL::integer, NULL::integer, NULL::integer,
            NULL::boolean, NULL::boolean, NULL::boolean,
            NULL::bigint, NULL::boolean, NULL::boolean, NULL::text,
            NULL::bigint, NULL::bigint, NULL::boolean, statement_timestamp(), FALSE
          WHERE NOT EXISTS (SELECT 1 FROM posts WHERE id = :post_id)
        ),
        fence AS (
          INSERT INTO credis_post_observation_fences(fence_id, post_id, observed_at)
          SELECT CAST(:fence_id AS uuid), post_id, observed_at AT TIME ZONE 'UTC' FROM observed
          RETURNING fence_id
        )
        SELECT observed.*, fence.fence_id::text AS fence_id FROM observed CROSS JOIN fence
      SQL
    end

    def render_post_evidence(post, fence_id: nil)
      return render json: { error: "unknown Post" }, status: :not_found if !post
      return render json: { error: "Post source incomplete" }, status: :unprocessable_entity if
        post.author_user_id.blank? || post.topic_id.blank? || post.post_number.blank? ||
          post.post_version.nil? || post.matched_topic_id.blank? ||
          (post.topic_archetype == Archetype.default && post.matched_category_id.blank?)

      ineligible =
        post.deleted || post.hidden || post.user_deleted || post.topic_deleted ||
          !post.topic_visible || post.topic_archetype != Archetype.default ||
          post.post_type != Post.types[:regular] || post.category_read_restricted
      evidence = {
               evidence_schema_version: fence_id ? 4 : 3,
               post_id: post.post_id,
               observed_at: post.observed_at.utc.iso8601(6),
               topic_id: post.topic_id,
               category_id: post.category_id,
               post_number: post.post_number,
               author_user_id: post.author_user_id,
               post_version: post.post_version,
               content_status: ineligible ? "ineligible" : "eligible",
               deleted: post.deleted,
               hidden: post.hidden,
               user_deleted: post.user_deleted,
               topic_deleted: post.topic_deleted,
               topic_visible: post.topic_visible,
               topic_archetype: post.topic_archetype,
               post_type: post.post_type,
               category_read_restricted: post.category_read_restricted,
             }
      evidence[:fence_id] = fence_id if fence_id
      render json: evidence
    end

    def authenticate_integration!
      head :forbidden if !RequestAuthentication.valid?(request)
    end

    def validated_limit
      raw = request.query_parameters.fetch("limit", MAX_LIMIT.to_s)
      return if !/\A\d+\z/.match?(raw.to_s)

      raw.to_i if raw.to_i.between?(1, MAX_LIMIT)
    end

    def valid_history_session?(session, binding:, token:, now:)
      session.present? && session.expires_at > now &&
        session.expires_at.utc.iso8601(6) == token.fetch(:expires_at).utc.iso8601(6) &&
        session.epoch_id == binding.fetch("epoch_id") &&
        session.from_occurred_at.utc.iso8601(6) == binding.fetch("from_occurred_at") &&
        session.to_occurred_at.utc.iso8601(6) == binding.fetch("to_occurred_at") &&
        session.page_limit == binding.fetch("limit")
    end

    def validated_history_query
      allowed = %w[epoch_id from_occurred_at to_occurred_at limit page_token]
      return if request.query_parameters.keys.any? { |key| !allowed.include?(key) }

      raw_epoch_id = request.query_parameters["epoch_id"].to_s
      return if !/\A\d+\z/.match?(raw_epoch_id) || raw_epoch_id.to_i < 1

      limit = validated_limit
      return if !limit

      from = Time.iso8601(request.query_parameters.fetch("from_occurred_at"))
      to = Time.iso8601(request.query_parameters.fetch("to_occurred_at"))
      return if from > to || (to - from) > MAX_HISTORY_RANGE

      epoch_id = raw_epoch_id.to_i
      {
        epoch_id: epoch_id,
        from: from,
        to: to,
        limit: limit,
        page_token: request.query_parameters["page_token"],
        binding: {
          "epoch_id" => epoch_id,
          "from_occurred_at" => from.utc.iso8601(6),
          "to_occurred_at" => to.utc.iso8601(6),
          "limit" => limit,
        },
      }
    rescue ArgumentError, KeyError
      nil
    end

    def validated_ack_uids
      payload = JSON.parse(request.raw_post)
      raise InvalidAck if !payload.is_a?(Hash) || payload.keys != ["event_uids"]

      event_uids = payload["event_uids"]
      raise InvalidAck if !event_uids.is_a?(Array) || !event_uids.length.between?(1, MAX_LIMIT)
      raise InvalidAck if event_uids.any? { |uid| !uid.is_a?(String) || !UUID_PATTERN.match?(uid) }

      event_uids.map(&:downcase).uniq.tap do |unique_uids|
        raise InvalidAck if unique_uids.length != event_uids.length
      end
    end

    def render_bad_request
      render json: { error: "invalid request" }, status: :bad_request
    end
  end
end
