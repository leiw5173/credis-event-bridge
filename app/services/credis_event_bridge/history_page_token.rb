# frozen_string_literal: true

require "base64"
require "openssl"

module CredisEventBridge
  class HistoryPageToken
    CONTEXT = "credis-event-bridge:history-page:v2"
    UUID_PATTERN =
      /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    PAYLOAD_KEYS = %w[after_position expires_at query session_id v].freeze

    class Invalid < StandardError
    end

    class << self
      def encode(query:, session:, after_position:)
        payload = {
          "v" => 2,
          "query" => query,
          "session_id" => session.id,
          "expires_at" => session.expires_at.utc.iso8601(6),
          "after_position" => after_position,
        }
        encoded = Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
        "#{encoded}.#{signature(encoded)}"
      end

      def decode(token, query:, now: Time.zone.now)
        encoded, provided_signature = token.to_s.split(".", 2)
        raise Invalid if encoded.blank? || provided_signature.blank?

        expected_signature = signature(encoded)
        raise Invalid if
          !ActiveSupport::SecurityUtils.secure_compare(expected_signature, provided_signature)

        payload = JSON.parse(Base64.urlsafe_decode64(padded(encoded)))
        raise Invalid if !payload.is_a?(Hash) || payload.keys.sort != PAYLOAD_KEYS
        raise Invalid if payload["v"] != 2 || payload["query"] != query
        raise Invalid if !UUID_PATTERN.match?(payload["session_id"].to_s)
        raise Invalid if !payload["after_position"].is_a?(Integer) || payload["after_position"] < 0

        expires_at = Time.iso8601(payload["expires_at"])
        raise Invalid if now >= expires_at

        {
          session_id: payload["session_id"],
          expires_at: expires_at,
          after_position: payload["after_position"],
        }
      rescue ArgumentError, JSON::ParserError, KeyError
        raise Invalid
      end

      private

      def signature(encoded)
        secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"].to_s
        raise Invalid if secret.bytesize < 32

        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{CONTEXT}\n#{encoded}")
      end

      def padded(encoded)
        encoded + ("=" * ((4 - (encoded.length % 4)) % 4))
      end
    end
  end
end
