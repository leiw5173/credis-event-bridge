# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "openssl"
require "resolv"
require "timeout"
require "uri"

module CredisEventBridge
  class Delivery
    BASE_BACKOFF = 30.seconds
    MAX_BACKOFF = 1.hour
    MAX_BACKOFF_EXPONENT = 16
    MAX_DELIVERY_ATTEMPTS = 2_147_483_647
    MAX_ACK_RESPONSE_BYTES = 8.kilobytes
    CLAIM_LEASE = 30.seconds
    REQUEST_DEADLINE = 20.seconds
    LEASE_SAFETY = 5.seconds
    DEFAULT_BATCH_SIZE = 50
    DELIVERY_LOCK_NAME = "credis-event-bridge:delivery-claim"
    SIGNATURE_CONTEXT = "credis-event-bridge-delivery-v1"
    CONFIGURATION_FINGERPRINT_CONTEXT = "credis-event-bridge-delivery-configuration-v1"
    TEST_HTTP_ENV = "CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"
    BLOCKED_PREFIX = "blocked:"
    RECEIVER_AUTH_BLOCKED_PREFIX = "blocked:receiver_authentication:"

    class InvalidConfiguration < StandardError
    end

    class ResponseTooLarge < StandardError
    end

    class RequestDeadlineExceeded < Timeout::Error
    end

    DeliveryResponse = Data.define(:code, :content_type, :body, :success)

    TRANSPORT_ERRORS = [
      EOFError,
      IOError,
      Net::HTTPBadResponse,
      OpenSSL::SSL::SSLError,
      SocketError,
      SystemCallError,
      Timeout::Error,
    ].freeze

    def initialize(open_timeout: 5, read_timeout: 10, total_timeout: REQUEST_DEADLINE)
      total_timeout = total_timeout.to_f
      if total_timeout <= 0 || total_timeout + LEASE_SAFETY.to_f >= CLAIM_LEASE.to_f
        raise ArgumentError, "delivery total timeout must be positive and leave claim lease safety"
      end

      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @total_timeout = total_timeout
    end

    def call(now: Time.zone.now)
      events = claim_batch(now: now)
      return [] if events.empty?

      transport_context = { receiver_authentication_rejected: false }
      uri, secret = configuration!
      fingerprint = configuration_fingerprint(uri: uri, secret: secret)
      body = JSON.generate(events: events.map { |event| EventPayload.call(event) })
      response =
        Timeout.timeout(@total_timeout, RequestDeadlineExceeded) do
          post(
            uri: uri,
            secret: secret,
            body: body,
            now: now,
            transport_context: transport_context,
          )
        end
      process_response(
        response,
        events: events,
        now: now,
        configuration_fingerprint: fingerprint,
      )
    rescue RequestDeadlineExceeded
      record_transport_failure(
        events,
        transport_context: transport_context,
        configuration_fingerprint: fingerprint,
        degraded_reason: "delivery_degraded:request_deadline_exceeded",
        now: now,
      ) if events.present?
      []
    rescue InvalidConfiguration
      block_batch(events, reason: "blocked:invalid_configuration", now: now) if events.present?
      Rails.logger.error("Credis event bridge delivery blocked: invalid configuration")
      []
    rescue ResponseTooLarge
      record_transport_failure(
        events,
        transport_context: transport_context,
        configuration_fingerprint: fingerprint,
        degraded_reason: "delivery_degraded:response_too_large",
        now: now,
      ) if events.present?
      []
    rescue *TRANSPORT_ERRORS => error
      record_transport_failure(
        events,
        transport_context: transport_context,
        configuration_fingerprint: fingerprint,
        degraded_reason: "delivery_degraded:#{error.class.name}",
        now: now,
      ) if events.present?
      []
    end

    private

    def claim_batch(now:)
      claimed = []
      ActiveRecord::Base.transaction(requires_new: true) do
        delivery_lock_acquired =
          DB.query_single(
            "SELECT pg_try_advisory_xact_lock(hashtextextended(:lock_name, 0))",
            lock_name: DELIVERY_LOCK_NAME,
          ).first
        next if !delivery_lock_acquired

        rows =
          CredisEventOutbox
            .lock
            .where(acked_at: nil)
            .order(:outbox_id)
            .limit(DEFAULT_BATCH_SIZE)
            .to_a
        next if rows.empty?
        next if blocked_for_current_configuration?(rows.first)
        next if rows.first.next_attempt_at.present? && rows.first.next_attempt_at > now

        claimed =
          rows.take_while do |event|
            !blocked_for_current_configuration?(event) &&
              (event.next_attempt_at.blank? || event.next_attempt_at <= now)
          end
        claimed.each do |event|
          attempts = [event.delivery_attempts + 1, MAX_DELIVERY_ATTEMPTS].min
          event.update_columns(
            delivery_attempts: attempts,
            delivery_claim_token: SecureRandom.uuid,
            next_attempt_at: now + CLAIM_LEASE,
            updated_at: now,
          )
        end
      end
      claimed
    end

    def blocked_for_current_configuration?(event)
      error = event.last_delivery_error.to_s
      return false if !error.start_with?(BLOCKED_PREFIX)
      return !configuration_valid? if error == "blocked:invalid_configuration"
      return true if !error.start_with?(RECEIVER_AUTH_BLOCKED_PREFIX)

      current_fingerprint = current_configuration_fingerprint
      return true if current_fingerprint.blank?

      stored_fingerprint = error.delete_prefix(RECEIVER_AUTH_BLOCKED_PREFIX)
      stored_fingerprint == current_fingerprint
    end

    def configuration_valid?
      configuration!
      true
    rescue InvalidConfiguration
      false
    end

    def current_configuration_fingerprint
      uri, secret = configuration!
      configuration_fingerprint(uri: uri, secret: secret)
    rescue InvalidConfiguration
      nil
    end

    def configuration_fingerprint(uri:, secret:)
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        secret,
        "#{CONFIGURATION_FINGERPRINT_CONTEXT}\n#{uri}",
      )
    end

    def configuration!
      secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"].to_s
      raise InvalidConfiguration if secret.bytesize < 32

      uri = URI.parse(ENV["CREDIS_EVENT_BRIDGE_URL"].to_s)
      raise InvalidConfiguration if uri.host.blank? || uri.userinfo.present?
      raise InvalidConfiguration if uri.query.present? || uri.fragment.present?
      raise InvalidConfiguration if uri.scheme != "https" && !test_loopback_http?(uri)

      [uri, secret]
    rescue URI::InvalidURIError
      raise InvalidConfiguration
    end

    def test_loopback_http?(uri)
      return false if !Rails.env.test? || ENV[TEST_HTTP_ENV] != "1" || uri.scheme != "http"

      IPAddr.new(uri.host).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    def post(uri:, secret:, body:, now:, transport_context:)
      timestamp = now.to_i.to_s
      nonce = SecureRandom.hex(16)
      target = uri.request_uri
      canonical =
        [
          SIGNATURE_CONTEXT,
          "POST",
          target,
          timestamp,
          nonce,
          Digest::SHA256.hexdigest(body),
        ].join("\n")
      signature = OpenSSL::HMAC.hexdigest("SHA256", secret, canonical)
      request = Net::HTTP::Post.new(target)
      request["Content-Type"] = "application/json"
      request["X-Credis-Timestamp"] = timestamp
      request["X-Credis-Nonce"] = nonce
      request["X-Credis-Signature"] = "v1=#{signature}"
      request.body = body

      http = Net::HTTP.new(uri.host, uri.port, nil)
      # Connect to one address resolved under a deadline while retaining uri.host for TLS SNI and
      # hostname verification. Net::HTTP does not follow redirects, so the pinned address is used
      # for this request only.
      http.ipaddr = resolve_address(uri.host)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @read_timeout

      request["Host"] ||= http.send(:addr_port)
      request["Connection"] = "close"
      parsed_response = nil
      http.start do |connection|
        socket = connection.instance_variable_get(:@socket)
        request.exec(socket, "1.1", target)
        response = read_final_response(socket, request: request, uri: uri, http: connection)
        if response.code.to_i == 403
          transport_context[:receiver_authentication_rejected] = true
          parsed_response = DeliveryResponse.new(code: 403, content_type: "", body: "", success: false)
          next
        end

        parsed_response = read_bounded_response(response, socket: socket, request: request)
      end
      parsed_response
    end

    def read_final_response(socket, request:, uri:, http:)
      response = nil
      loop do
        response = Net::HTTPResponse.read_new(socket)
        response.decode_content = request.decode_content
        response.body_encoding = http.instance_variable_get(:@response_body_encoding)
        response.ignore_eof = http.instance_variable_get(:@ignore_eof)
        response.uri = uri
        break if !response.is_a?(Net::HTTPInformation)
      end
      response
    end

    def read_bounded_response(response, socket:, request:)
      content_length = response["Content-Length"]
      raise ResponseTooLarge if
        content_length.present? && content_length.to_i > MAX_ACK_RESPONSE_BYTES

      response_body = +""
      response.reading_body(socket, request.response_body_permitted?) do
        response.read_body do |chunk|
          raise ResponseTooLarge if response_body.bytesize + chunk.bytesize > MAX_ACK_RESPONSE_BYTES

          response_body << chunk
        end
      end
      DeliveryResponse.new(
        code: response.code.to_i,
        content_type: response["Content-Type"].to_s,
        body: response_body,
        success: response.is_a?(Net::HTTPSuccess),
      )
    end

    def resolve_address(host)
      IPAddr.new(host).to_s
    rescue IPAddr::InvalidAddressError
      address = Timeout.timeout(@open_timeout) { Resolv.getaddresses(host).first }
      raise SocketError, "delivery endpoint could not be resolved" if address.blank?

      address
    end

    def record_transport_failure(
      events,
      transport_context:,
      configuration_fingerprint:,
      degraded_reason:,
      now:
    )
      if transport_context&.fetch(:receiver_authentication_rejected, false)
        block_batch(
          events,
          reason: "#{RECEIVER_AUTH_BLOCKED_PREFIX}#{configuration_fingerprint}",
          now: now,
        )
        Rails.logger.error("Credis event bridge delivery blocked: receiver authentication failed")
      else
        degrade_batch(events, reason: degraded_reason, now: now)
      end
    end

    def process_response(response, events:, now:, configuration_fingerprint:)
      if response.code == 403
        block_batch(
          events,
          reason: "#{RECEIVER_AUTH_BLOCKED_PREFIX}#{configuration_fingerprint}",
          now: now,
        )
        Rails.logger.error("Credis event bridge delivery blocked: receiver authentication failed")
        return []
      end

      if !response.success
        degrade_batch(
          events,
          reason: "delivery_degraded:http_#{response.code}",
          now: now,
        )
        return []
      end

      if !durable_ack?(response, events: events)
        degrade_batch(
          events,
          reason: "delivery_degraded:missing_durable_ack",
          now: now,
        )
        return []
      end

      acknowledge_batch(events, now: now)
      events.map(&:event_uid)
    end

    def durable_ack?(response, events:)
      content_type = response.content_type.split(";", 2).first.to_s.downcase
      return false if content_type != "application/json"

      payload = JSON.parse(response.body)
      return false if !payload.is_a?(Hash) || payload.keys.sort != %w[durable_ack event_uids]
      return false if payload["durable_ack"] != true

      event_uids = payload["event_uids"]
      expected = events.map(&:event_uid)
      event_uids.is_a?(Array) && event_uids.all? { |uid| uid.is_a?(String) } &&
        event_uids.uniq.length == event_uids.length && event_uids.length == expected.length &&
        event_uids.to_set == expected.to_set
    rescue JSON::ParserError
      false
    end

    def acknowledge_batch(events, now:)
      update_claimed(events) do |scope, _event|
        scope.update_all(
          acked_at: now,
          delivery_claim_token: nil,
          next_attempt_at: nil,
          last_delivery_error: nil,
          updated_at: now,
        )
      end
    end

    def degrade_batch(events, reason:, now:)
      update_claimed(events) do |scope, event|
        exponent = [[event.delivery_attempts - 1, 0].max, MAX_BACKOFF_EXPONENT].min
        backoff = [BASE_BACKOFF * (2**exponent), MAX_BACKOFF].min
        scope.update_all(
          delivery_claim_token: nil,
          next_attempt_at: now + backoff,
          last_delivery_error: reason,
          updated_at: now,
        )
      end
      Rails.logger.warn("Credis event bridge delivery degraded: #{reason.delete_prefix("delivery_degraded:")}")
    end

    def block_batch(events, reason:, now:)
      update_claimed(events) do |scope, _event|
        scope.update_all(
          delivery_claim_token: nil,
          next_attempt_at: nil,
          last_delivery_error: reason,
          updated_at: now,
        )
      end
    end

    def update_claimed(events)
      ActiveRecord::Base.transaction(requires_new: true) do
        events.each do |event|
          next if event.delivery_claim_token.blank?

          scope =
            CredisEventOutbox.where(
              event_uid: event.event_uid,
              acked_at: nil,
              delivery_claim_token: event.delivery_claim_token,
            )
          yield scope, event
        end
      end
    end
  end
end
