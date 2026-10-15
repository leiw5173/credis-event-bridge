# frozen_string_literal: true

require "socket"

module CredisEventBridgeSpec
  class LoopbackReceiver
    attr_reader :url

    def initialize(&handler)
      @handler = handler
      @server = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@server.addr[1]}/ingest"
      @requests = []
      @ledger = {}
      @client_threads = []
      @mutex = Mutex.new
      ready = Queue.new
      @thread =
        Thread.new do
          ready << true
          accept_requests
        end
      ready.pop
    end

    def requests
      @mutex.synchronize { @requests.map(&:dup) }
    end

    def ledger
      @mutex.synchronize { @ledger.transform_values(&:dup) }
    end

    def close
      @server.close
      @thread.join(2)
      @mutex.synchronize { @client_threads.dup }.each { |thread| thread.join(2) }
    rescue IOError, Errno::EBADF
      nil
    end

    private

    def accept_requests
      loop do
        socket = @server.accept
        thread =
          Thread.new do
            handle(socket)
          rescue IOError, Errno::EPIPE, Errno::ECONNRESET
            nil
          end
        @mutex.synchronize { @client_threads << thread }
      rescue IOError, Errno::EBADF
        break
      end
    end

    def handle(socket)
      request_line = socket.gets("\r\n")
      return if request_line.blank?

      method, target, = request_line.split(" ", 3)
      headers = {}
      while (line = socket.gets("\r\n")) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      request = { method: method, target: target, headers: headers, body: body }
      attempt = nil
      @mutex.synchronize do
        @requests << request
        attempt = @requests.length
        JSON.parse(body).fetch("events").each do |event|
          @ledger[event.fetch("event_uid")] ||= event
        end
      end

      response = @handler.call(request, attempt)
      return if response == :drop

      sleep(response.fetch(:delay)) if response[:delay]
      status = response.fetch(:status)
      response_body =
        if response[:chunks]
          response.fetch(:chunks).join
        elsif response.key?(:raw_body)
          response.fetch(:raw_body)
        else
          JSON.generate(response.fetch(:body, {}))
        end
      reason =
        {
          200 => "OK",
          202 => "Accepted",
          302 => "Found",
          403 => "Forbidden",
          500 => "Internal Server Error",
        }.fetch(status, "Response")
      response_headers =
        "HTTP/1.1 #{status} #{reason}\r\n" \
          "Content-Type: #{response.fetch(:content_type, "application/json")}\r\n"
      if !response[:omit_content_length]
        declared_length = response.fetch(:content_length, response_body.bytesize)
        response_headers += "Content-Length: #{declared_length}\r\n"
      end
      response_headers += "Location: #{response[:location]}\r\n" if response[:location]
      response_headers += "Connection: close\r\n\r\n"
      socket.write(response_headers)
      socket.flush
      sleep(response.fetch(:hold_after_headers)) if response[:hold_after_headers]
      if response[:chunks]
        response.fetch(:chunks).each do |chunk|
          socket.write(chunk)
          sleep(response.fetch(:chunk_delay, 0))
        end
      else
        socket.write(response_body)
      end
    ensure
      socket.close
    end
  end
end

RSpec.describe CredisEventBridge::Delivery do
  SECRET = "task-3-delivery-secret-with-at-least-32-bytes"

  fab!(:actor, :user)
  fab!(:epoch) { CredisEventBridge::EpochLifecycle.start! }

  around do |example|
    previous_secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"]
    previous_url = ENV["CREDIS_EVENT_BRIDGE_URL"]
    previous_test_http = ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"]
    ENV["CREDIS_EVENT_BRIDGE_SECRET"] = SECRET
    ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"] = "1"
    ENV.delete("CREDIS_EVENT_BRIDGE_URL")
    example.run
  ensure
    previous_secret ? ENV["CREDIS_EVENT_BRIDGE_SECRET"] = previous_secret : ENV.delete("CREDIS_EVENT_BRIDGE_SECRET")
    previous_url ? ENV["CREDIS_EVENT_BRIDGE_URL"] = previous_url : ENV.delete("CREDIS_EVENT_BRIDGE_URL")
    previous_test_http ? ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"] = previous_test_http : ENV.delete("CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP")
  end

  def create_event(occurred_at: Time.zone.now, source_snapshot: nil)
    target_id = 9_700_000 + SecureRandom.random_number(100_000)
    relation =
      CredisRelationRevision.create!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_id,
        state_code: "ordinary_like",
        revision: 1,
      )
    CredisEventOutbox.create!(
      event_uid: SecureRandom.uuid,
      epoch_id: epoch.id,
      relation_revision_id: relation.id,
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: target_id,
      revision: 1,
      operation_id: SecureRandom.uuid,
      from_state: "none",
      to_state: "ordinary_like",
      occurred_at: occurred_at,
      origin: "outbox_delivery_spec",
      **(source_snapshot || {}),
    )
  end

  def durable_ack_response(request, status: 200)
    event_uids = JSON.parse(request.fetch(:body)).fetch("events").map { |event| event.fetch("event_uid") }
    { status: status, body: { durable_ack: true, event_uids: event_uids } }
  end

  def with_receiver(handler)
    previous_connect_on_start = WebMock::Config.instance.net_http_connect_on_start
    receiver = CredisEventBridgeSpec::LoopbackReceiver.new(&handler)
    WebMock::Config.instance.net_http_connect_on_start = true
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url
    yield receiver
  ensure
    WebMock::Config.instance.net_http_connect_on_start = previous_connect_on_start
    receiver&.close
  end

  def expect_valid_delivery_signature(request)
    timestamp = request.fetch(:headers).fetch("x-credis-timestamp")
    nonce = request.fetch(:headers).fetch("x-credis-nonce")
    canonical =
      [
        "credis-event-bridge-delivery-v1",
        "POST",
        request.fetch(:target),
        timestamp,
        nonce,
        Digest::SHA256.hexdigest(request.fetch(:body)),
      ].join("\n")
    expected = OpenSSL::HMAC.hexdigest("SHA256", SECRET, canonical)
    expect(request.fetch(:headers).fetch("x-credis-signature")).to eq("v1=#{expected}")
  end

  it "recovers a committed event without an enqueue and ACKs only an explicit durable receiver response" do
    event = create_event
    business_before = event.attributes.slice(*CredisEventOutbox::BUSINESS_FIELDS.map(&:to_s))

    with_receiver(
      ->(request, _attempt) { durable_ack_response(request) },
    ) do |receiver|
      Jobs::CredisEventBridge::DeliverOutbox.new.execute({})

      expect(receiver.requests.length).to eq(1)
      expect_valid_delivery_signature(receiver.requests.first)
    end

    expect(event.reload.acked_at).to be_present
    expect(event.delivery_attempts).to eq(1)
    expect(event.attributes.slice(*CredisEventOutbox::BUSINESS_FIELDS.map(&:to_s))).to eq(
      business_before,
    )
  end

  it "pushes the persisted source snapshot with the signed event" do
    snapshot = {
      snapshot_schema_version: 1,
      target_author_user_id: actor.id,
      target_post_version: 2,
      target_content_status: "eligible",
      target_deleted: false,
      target_hidden: false,
      target_user_deleted: false,
      target_snapshot_captured_at: Time.zone.now,
      reaction_settings_digest: "a" * 64,
    }
    event = create_event(source_snapshot: snapshot)
    expected = snapshot.transform_keys(&:to_s).transform_values do |value|
      value.is_a?(Time) ? value.iso8601(6) : value
    end

    with_receiver(->(request, _attempt) { durable_ack_response(request) }) do |receiver|
      Jobs::CredisEventBridge::DeliverOutbox.new.execute({})
      expect(receiver.requests.length).to eq(1)
      expect_valid_delivery_signature(receiver.requests.first)
      pushed = JSON.parse(receiver.requests.first.fetch(:body)).fetch("events").first
      expect(pushed.slice(*expected.keys)).to eq(expected)
    end
    expect(event.reload.acked_at).to be_present
  end

  it "retries response loss with the identical UID and business payload without duplicating the receiver ledger" do
    event = create_event
    started_at = Time.zone.now

    with_receiver(
      lambda do |request, attempt|
        attempt == 1 ? :drop : durable_ack_response(request)
      end,
    ) do |receiver|
      described_class.new.call(now: started_at)
      first_retry_at = event.reload.next_attempt_at
      expect(event.acked_at).to be_nil
      expect(event.last_delivery_error).to start_with("delivery_degraded:")

      described_class.new.call(now: first_retry_at + 1.second)

      expect(receiver.requests.length).to eq(2)
      first_events = JSON.parse(receiver.requests.first.fetch(:body)).fetch("events")
      second_events = JSON.parse(receiver.requests.second.fetch(:body)).fetch("events")
      expect(second_events).to eq(first_events)
      expect(first_events.first.fetch("event_uid")).to eq(event.event_uid)
      expect(receiver.ledger.keys).to eq([event.event_uid])
    end

    expect(event.reload.acked_at).to be_present
    expect(CredisEventOutbox.where(event_uid: event.event_uid).count).to eq(1)
  end

  it "keeps 500 and unknown 2xx responses retryable with exponential backoff and never marks capture incomplete" do
    event = create_event
    epoch_snapshot =
      epoch.reload.attributes.slice(
        "status",
        "baseline_complete",
        "baseline_digest",
        "compatibility_token",
        "incomplete_reason",
        "quarantine_scope",
      )
    started_at = Time.zone.now

    with_receiver(
      lambda do |request, attempt|
        if attempt == 1
          { status: 500, body: { error: "temporary" } }
        elsif attempt == 2
          { status: 202, body: { accepted: true } }
        else
          durable_ack_response(request)
        end
      end,
    ) do
      described_class.new.call(now: started_at)
      first_retry_at = event.reload.next_attempt_at
      expect(event.last_delivery_error).to eq("delivery_degraded:http_500")

      described_class.new.call(now: first_retry_at + 1.second)
      second_retry_at = event.reload.next_attempt_at
      expect(event.last_delivery_error).to eq("delivery_degraded:missing_durable_ack")
      expect(second_retry_at - (first_retry_at + 1.second)).to be >= 2 * described_class::BASE_BACKOFF

      described_class.new.call(now: second_retry_at + 1.second)
    end

    expect(event.reload.acked_at).to be_present
    expect(epoch.reload.attributes.slice(*epoch_snapshot.keys)).to eq(epoch_snapshot)
  end

  it "times out a late loopback response and leaves the same event retryable" do
    event = create_event

    with_receiver(
      lambda do |request, _attempt|
        durable_ack_response(request).merge(delay: 0.2)
      end,
    ) do |receiver|
      described_class.new(read_timeout: 0.05, open_timeout: 0.05).call

      expect(receiver.requests.length).to eq(1)
    end

    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("delivery_degraded:Net::ReadTimeout")
    expect(event.next_attempt_at).to be_present
    expect(epoch.reload.status).to eq("collecting")
  end

  it "aborts a trickle response on a total deadline shorter than the claim lease" do
    event = create_event
    expect { described_class.new(total_timeout: 0) }.to raise_error(ArgumentError)
    response_body = JSON.generate(durable_ack: true, event_uids: [event.event_uid])
    chunks = response_body.scan(/.{1,12}/m)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    with_receiver(
      lambda do |_request, _attempt|
        {
          status: 200,
          chunks: chunks,
          chunk_delay: 0.08,
          omit_content_length: true,
        }
      end,
    ) do
      described_class
        .new(open_timeout: 0.2, read_timeout: 0.2, total_timeout: 0.2)
        .call
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(described_class::REQUEST_DEADLINE + described_class::LEASE_SAFETY).to be <
      described_class::CLAIM_LEASE
    expect(elapsed).to be < 0.6
    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("delivery_degraded:request_deadline_exceeded")
  end

  it "blocks immediately on oversized slow 403 headers without consuming the body" do
    event = create_event
    elapsed = nil

    with_receiver(
      lambda do |_request, _attempt|
        {
          status: 403,
          raw_body: "",
          content_length: 10_000,
          hold_after_headers: 2,
        }
      end,
    ) do |receiver|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class
        .new(open_timeout: 0.5, read_timeout: 0.5, total_timeout: 1.0)
        .call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(receiver.requests.length).to eq(1)
      expect(event.reload.last_delivery_error).to match(
        /\Ablocked:receiver_authentication:[0-9a-f]{64}\z/,
      )

      described_class.new.call(now: 1.day.from_now)
      expect(receiver.requests.length).to eq(1)
    end

    expect(elapsed).to be < 1.5
    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to match(
      /\Ablocked:receiver_authentication:[0-9a-f]{64}\z/,
    )
    expect(event.last_delivery_error).not_to include(SECRET)
  end

  it "blocks receiver 403 for the same configuration and resumes the same UID after rotation" do
    event = create_event
    messages = nil

    track_log_messages do |logger|
      with_receiver(
        lambda do |request, attempt|
          attempt == 1 ? { status: 403, body: {} } : durable_ack_response(request)
        end,
      ) do |receiver|
        described_class.new.call
        described_class.new.call(now: 1.day.from_now)
        expect(receiver.requests.length).to eq(1)
        blocked_error = event.reload.last_delivery_error
        expect(blocked_error).to match(/\Ablocked:receiver_authentication:[0-9a-f]{64}\z/)
        expect(blocked_error).not_to include(SECRET)

        ENV["CREDIS_EVENT_BRIDGE_SECRET"] = "rotated-task-3-delivery-secret-with-at-least-32-bytes"
        described_class.new.call(now: 2.days.from_now)

        expect(receiver.requests.length).to eq(2)
        delivered_uids =
          receiver.requests.map do |request|
            JSON.parse(request.fetch(:body)).fetch("events").sole.fetch("event_uid")
          end
        expect(delivered_uids).to eq([event.event_uid, event.event_uid])
      end
      messages = logger.errors.join("\n")
    end

    expect(event.reload.acked_at).to be_present
    expect(event.last_delivery_error).to be_nil
    expect(messages).to include("delivery blocked")
    expect(messages).not_to include(SECRET)
  end

  it "blocks invalid non-loopback HTTP configuration, then recovers after configuration is fixed" do
    event = create_event
    ENV["CREDIS_EVENT_BRIDGE_URL"] = "http://example.invalid/ingest"

    described_class.new.call

    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("blocked:invalid_configuration")
    expect(event.last_delivery_error).not_to include(SECRET)

    with_receiver(
      ->(request, _attempt) { durable_ack_response(request) },
    ) do |receiver|
      described_class.new.call
      expect(receiver.requests.length).to eq(1)
    end

    expect(event.reload.acked_at).to be_present
  end

  it "rejects cleartext loopback in production even when the test override is set" do
    expect(Scheduler::Defer.async).to eq(false)
    event = create_event

    with_receiver(
      ->(request, _attempt) { durable_ack_response(request) },
    ) do |receiver|
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      described_class.new.call

      expect(receiver.requests).to be_empty
    end

    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("blocked:invalid_configuration")
    expect(Scheduler::Defer.async).to eq(false)
  end

  it "rejects textual localhost instead of allowing DNS rebinding in test HTTP mode" do
    event = create_event
    receiver =
      CredisEventBridgeSpec::LoopbackReceiver.new do |request, _attempt|
        durable_ack_response(request)
      end
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url.sub("127.0.0.1", "localhost")

    described_class.new.call

    expect(receiver.requests).to be_empty
    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("blocked:invalid_configuration")
  ensure
    receiver&.close
  end

  it "treats every malformed or ambiguous 2xx ACK shape as retryable degradation" do
    first = create_event
    second = create_event
    responses =
      lambda do |request, attempt|
        event_uids =
          JSON.parse(request.fetch(:body)).fetch("events").map { |event| event.fetch("event_uid") }
        case attempt
        when 1
          { status: 200, raw_body: "true" }
        when 2
          { status: 200, raw_body: "[]" }
        when 3
          { status: 200, body: { durable_ack: true } }
        when 4
          { status: 200, body: { durable_ack: true, event_uids: event_uids, extra: true } }
        when 5
          { status: 200, body: { durable_ack: true, event_uids: [event_uids.first, event_uids.first] } }
        when 6
          { status: 200, body: { durable_ack: true, event_uids: [event_uids.first] } }
        when 7
          durable_ack_response(request).merge(content_type: "text/plain")
        else
          durable_ack_response(request)
        end
      end
    now = Time.zone.now

    with_receiver(responses) do |receiver|
      7.times do
        described_class.new.call(now: now)
        expect(first.reload.acked_at).to be_nil
        expect(second.reload.acked_at).to be_nil
        expect(first.last_delivery_error).to eq("delivery_degraded:missing_durable_ack")
        now = [first, second].map { |event| event.reload.next_attempt_at }.max + 1.second
      end

      described_class.new.call(now: now)
      expect(receiver.requests.length).to eq(8)
    end

    expect(first.reload.acked_at).to be_present
    expect(second.reload.acked_at).to be_present
  end

  it "rejects oversized ACK bodies with and without Content-Length" do
    event = create_event
    oversized_body = JSON.generate(durable_ack: true, event_uids: [event.event_uid], padding: "x" * 10_000)
    now = Time.zone.now

    with_receiver(
      lambda do |_request, attempt|
        {
          status: 200,
          raw_body: oversized_body,
          omit_content_length: attempt == 2,
        }
      end,
    ) do |receiver|
      described_class.new.call(now: now)
      expect(event.reload.last_delivery_error).to eq("delivery_degraded:response_too_large")

      now = event.next_attempt_at + 1.second
      described_class.new.call(now: now)
      expect(event.reload.last_delivery_error).to eq("delivery_degraded:response_too_large")
      expect(receiver.requests.length).to eq(2)
    end

    expect(event.reload.acked_at).to be_nil
  end

  it "does not follow receiver redirects" do
    event = create_event

    with_receiver(
      ->(_request, _attempt) { { status: 302, body: {}, location: "https://example.invalid/" } },
    ) do |receiver|
      described_class.new.call
      expect(receiver.requests.length).to eq(1)
    end

    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("delivery_degraded:http_302")
  end

  it "caps delivery attempts and exponential backoff before integer overflow" do
    event = create_event
    event.update_columns(delivery_attempts: 2_147_483_647)
    now = Time.zone.now

    with_receiver(
      ->(_request, _attempt) { { status: 500, body: {} } },
    ) do
      expect { described_class.new.call(now: now) }.not_to raise_error
    end

    expect(event.reload.delivery_attempts).to eq(2_147_483_647)
    expect(event.next_attempt_at).to be <= now + described_class::MAX_BACKOFF
  end

  it "keeps a 2xx response unacknowledged when the durable ACK UID set does not exactly match" do
    event = create_event

    with_receiver(
      lambda do |_request, _attempt|
        { status: 200, body: { durable_ack: true, event_uids: [SecureRandom.uuid] } }
      end,
    ) do
      described_class.new.call
    end

    expect(event.reload.acked_at).to be_nil
    expect(event.last_delivery_error).to eq("delivery_degraded:missing_durable_ack")
  end

  it "makes repeated scheduled and regular scans idempotent after delivery" do
    event = create_event

    with_receiver(
      ->(request, _attempt) { durable_ack_response(request) },
    ) do |receiver|
      Jobs::CredisEventBridge::ScanOutbox.new.execute({})
      Jobs::CredisEventBridge::DeliverOutbox.new.execute({})

      expect(receiver.requests.length).to eq(1)
    end

    expect(event.reload.acked_at).to be_present
  end
end

RSpec.describe "Credis Event Bridge committed-outbox recovery" do
  self.use_transactional_tests = false

  RECOVERY_SECRET = "task-3-recovery-secret-with-at-least-32-bytes"

  let(:actor) { Discourse.system_user }
  let(:target_id) { 9_900_000 + SecureRandom.random_number(100_000) }

  around do |example|
    previous_secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"]
    previous_url = ENV["CREDIS_EVENT_BRIDGE_URL"]
    previous_test_http = ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"]
    previous_connect_on_start = WebMock::Config.instance.net_http_connect_on_start
    ENV["CREDIS_EVENT_BRIDGE_SECRET"] = RECOVERY_SECRET
    ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"] = "1"
    WebMock::Config.instance.net_http_connect_on_start = true
    example.run
  ensure
    previous_secret ? ENV["CREDIS_EVENT_BRIDGE_SECRET"] = previous_secret : ENV.delete("CREDIS_EVENT_BRIDGE_SECRET")
    previous_url ? ENV["CREDIS_EVENT_BRIDGE_URL"] = previous_url : ENV.delete("CREDIS_EVENT_BRIDGE_URL")
    previous_test_http ? ENV["CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP"] = previous_test_http : ENV.delete("CREDIS_EVENT_BRIDGE_ALLOW_TEST_HTTP")
    WebMock::Config.instance.net_http_connect_on_start = previous_connect_on_start
  end

  before do
    @epoch = CredisEventBridge::EpochLifecycle.start!
    @relation =
      CredisRelationRevision.create!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_id,
        state_code: "ordinary_like",
        revision: 1,
      )
    @relations = [@relation]
  end

  after do
    if @epoch
      CredisEventOutbox.where(epoch_id: @epoch.id).delete_all
      Array(@relations).each(&:destroy!)
      @epoch.destroy!
    end
  end

  def create_committed_event(relation, origin:)
    CredisEventOutbox.create!(
      event_uid: SecureRandom.uuid,
      epoch_id: @epoch.id,
      relation_revision_id: relation.id,
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: relation.target_id,
      revision: 1,
      operation_id: SecureRandom.uuid,
      from_state: "none",
      to_state: "ordinary_like",
      origin: origin,
    )
  end

  def wait_for_database_block_or_finish(backend_pid, thread)
    observer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    Timeout.timeout(5) do
      loop do
        blockers =
          observer
            .exec_params("SELECT cardinality(pg_blocking_pids($1))", [backend_pid])
            .getvalue(0, 0)
            .to_i
        return :blocked if blockers.positive?
        return :finished if !thread.alive?

        Thread.pass
      end
    end
  ensure
    observer&.close
  end

  it "does not overtake an earliest unacknowledged row locked by another scanner" do
    first = create_committed_event(@relation, origin: "claim_lock_first")
    second_relation =
      CredisRelationRevision.create!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_id + 1,
        state_code: "ordinary_like",
        revision: 1,
      )
    @relations << second_relation
    second = create_committed_event(second_relation, origin: "claim_lock_second")
    ActiveRecord::Base.connection_pool.release_connection
    first_locked = Queue.new
    release_first = Queue.new
    delivery_backend_pid = Queue.new

    locker_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            CredisEventOutbox.lock.find(first.id)
            first_locked << true
            release_first.pop
          end
        end
      end
    first_locked.pop

    receiver =
      CredisEventBridgeSpec::LoopbackReceiver.new do |request, _attempt|
        event_uids =
          JSON.parse(request.fetch(:body)).fetch("events").map { |event| event.fetch("event_uid") }
        { status: 200, body: { durable_ack: true, event_uids: event_uids } }
      end
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url
    delivery_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          delivery_backend_pid << DB.query_single("SELECT pg_backend_pid()").first
          CredisEventBridge::Delivery.new.call
        end
      end

    expect(wait_for_database_block_or_finish(delivery_backend_pid.pop, delivery_thread)).to eq(
      :blocked,
    )
    expect(receiver.requests).to be_empty

    release_first << true
    locker_thread.value
    delivery_thread.value

    expect(receiver.requests.length).to eq(1)
    expect(first.reload.acked_at).to be_present
    expect(second.reload.acked_at).to be_present
  ensure
    release_first << true if defined?(release_first) && locker_thread&.alive?
    locker_thread&.join
    delivery_thread&.join
    receiver&.close
  end

  it "prevents an expired older attempt from overwriting a newer 403 block" do
    event = create_committed_event(@relation, origin: "overlapping_attempt_fence")
    started_at = Time.zone.now
    ActiveRecord::Base.connection_pool.release_connection
    receiver =
      CredisEventBridgeSpec::LoopbackReceiver.new do |request, attempt|
        if attempt == 1
          { status: 500, body: {}, delay: 0.5 }
        elsif attempt == 2
          { status: 403, body: {} }
        else
          event_uids =
            JSON.parse(request.fetch(:body)).fetch("events").map { |payload| payload.fetch("event_uid") }
          { status: 200, body: { durable_ack: true, event_uids: event_uids } }
        end
      end
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url
    older_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          CredisEventBridge::Delivery
            .new(open_timeout: 1, read_timeout: 1, total_timeout: 2)
            .call(now: started_at)
        end
      end
    Timeout.timeout(2) { Thread.pass until receiver.requests.length == 1 }

    CredisEventBridge::Delivery.new.call(
      now: started_at + CredisEventBridge::Delivery::CLAIM_LEASE + 1.second,
    )
    blocked_error = event.reload.last_delivery_error
    expect(blocked_error).to match(/\Ablocked:receiver_authentication:[0-9a-f]{64}\z/)

    older_thread.value

    expect(event.reload.last_delivery_error).to eq(blocked_error)
    expect(event.acked_at).to be_nil
    expect(receiver.requests.first(2).map { |request| request.fetch(:body) }.uniq.length).to eq(1)

    ENV["CREDIS_EVENT_BRIDGE_SECRET"] =
      "rotated-task-3-recovery-secret-with-at-least-32-bytes"
    CredisEventBridge::Delivery.new.call(
      now: started_at + (2 * CredisEventBridge::Delivery::CLAIM_LEASE) + 2.seconds,
    )

    expect(receiver.requests.length).to eq(3)
    expect(event.reload.acked_at).to be_present
  ensure
    older_thread&.join
    receiver&.close
  end

  it "recovers after a worker claims a committed event and exits before sending" do
    event = create_committed_event(@relation, origin: "claimed_worker_exit")
    started_at = Time.zone.now
    claimed_uids =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          CredisEventBridge::Delivery
            .new
            .send(:claim_batch, now: started_at)
            .map(&:event_uid)
        end
      end.value
    expect(claimed_uids).to eq([event.event_uid])
    ActiveRecord::Base.connection_pool.release_connection

    receiver =
      CredisEventBridgeSpec::LoopbackReceiver.new do |request, _attempt|
        event_uids =
          JSON.parse(request.fetch(:body)).fetch("events").map { |payload| payload.fetch("event_uid") }
        { status: 200, body: { durable_ack: true, event_uids: event_uids } }
      end
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url

    CredisEventBridge::Delivery.new.call(
      now: started_at + CredisEventBridge::Delivery::CLAIM_LEASE - 1.second,
    )
    expect(receiver.requests).to be_empty

    CredisEventBridge::Delivery.new.call(
      now: started_at + CredisEventBridge::Delivery::CLAIM_LEASE + 1.second,
    )
    expect(receiver.requests.length).to eq(1)
    expect(event.reload.acked_at).to be_present
  ensure
    receiver&.close
  end

  it "delivers the original UID after the committing worker exits before any send" do
    committed_uid =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            CredisEventOutbox.create!(
              event_uid: SecureRandom.uuid,
              epoch_id: @epoch.id,
              relation_revision_id: @relation.id,
              relation_kind: "interaction",
              actor_user_id: actor.id,
              target_type: "Post",
              target_id: target_id,
              revision: 1,
              operation_id: SecureRandom.uuid,
              from_state: "none",
              to_state: "ordinary_like",
              origin: "committed_worker_exit",
            ).event_uid
          end
        end
      end.value
    ActiveRecord::Base.connection_pool.release_connection

    receiver =
      CredisEventBridgeSpec::LoopbackReceiver.new do |request, _attempt|
        event_uids =
          JSON.parse(request.fetch(:body)).fetch("events").map { |event| event.fetch("event_uid") }
        { status: 200, body: { durable_ack: true, event_uids: event_uids } }
      end
    ENV["CREDIS_EVENT_BRIDGE_URL"] = receiver.url

    Jobs::CredisEventBridge::ScanOutbox.new.execute({})

    expect(receiver.requests.length).to eq(1)
    delivered_uid =
      JSON.parse(receiver.requests.first.fetch(:body)).fetch("events").sole.fetch("event_uid")
    expect(delivered_uid).to eq(committed_uid)
    expect(CredisEventOutbox.find_by!(event_uid: committed_uid).acked_at).to be_present
  ensure
    receiver&.close
  end
end
