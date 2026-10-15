# frozen_string_literal: true

require "openssl"

module CredisEventBridge
  class RequestAuthentication
    TIMESTAMP_WINDOW = 5.minutes
    NONCE_TTL_SAFETY = 5.seconds
    SIGNATURE_CONTEXT = "credis-event-bridge-request-v1"
    NONCE_PATTERN = /\A[A-Za-z0-9_-]{16,128}\z/
    SIGNATURE_PATTERN = /\Av1=([0-9a-f]{64})\z/
    NONCE_PREFIX = "credis-event-bridge:request-nonce:"

    class << self
      def valid?(request, now: Time.now)
        secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"].to_s
        return false if secret.bytesize < 32

        timestamp = Integer(request.headers["X-Credis-Timestamp"], 10)
        return false if (now.to_i - timestamp).abs > TIMESTAMP_WINDOW.to_i

        nonce = request.headers["X-Credis-Nonce"].to_s
        return false if !NONCE_PATTERN.match?(nonce)

        signature_match = SIGNATURE_PATTERN.match(request.headers["X-Credis-Signature"].to_s)
        return false if !signature_match

        canonical =
          [
            SIGNATURE_CONTEXT,
            request.request_method,
            request.fullpath,
            timestamp.to_s,
            nonce,
            Digest::SHA256.hexdigest(request.raw_post.to_s),
          ].join("\n")
        expected = OpenSSL::HMAC.hexdigest("SHA256", secret, canonical)
        return false if
          !ActiveSupport::SecurityUtils.secure_compare(expected, signature_match[1])

        nonce_ttl =
          timestamp + TIMESTAMP_WINDOW.to_i - now.to_i + NONCE_TTL_SAFETY.to_i
        Discourse.redis.set(
          NONCE_PREFIX + Digest::SHA256.hexdigest(nonce),
          "1",
          nx: true,
          ex: nonce_ttl,
        ) == true
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
